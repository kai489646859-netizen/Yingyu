import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

const mib = 1024 * 1024;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    for (final speed in [2.0, 3.0])
      for (final variant in [
        'strong',
        'weak',
        'missing',
        'changed',
        'length',
        'redirect',
        'denied',
        'cut',
        'cut_twice',
      ])
        (speed: speed, variant: variant),
  ]) {
    final variant = scenario.variant;
    final speed = scenario.speed;
    test(
      '$speed x loopback $variant preserves entry count, identity, bytes and bounded bodies',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final media = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final sockets = <Socket>[];
          var entries = 0, active = 0, peak = 0, partRequests = 0;
          const total = 72 * mib;
          final ranges = <String>[];
          final events = <String>[];
          final timeline = Stopwatch()..start();
          final serveDone = <Future<void>>[];
          origin.listen((r) async {
            entries++;
            expect(r.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
            r.response.statusCode = 302;
            r.response.headers.set(
              'Location',
              'http://127.0.0.1:${media.port}/film.iso?sig=%2f%2B&x=a+b&x=2',
            );
            await r.response.close();
          });
          media.listen((socket) {
            sockets.add(socket);
            var headers = '',
                handled = false,
                counted = false,
                disconnected = false,
                range = '';
            void retireBody() {
              if (counted) {
                counted = false;
                active--;
                events.add(
                  '${timeline.elapsedMilliseconds} close $range active=$active',
                );
              }
            }

            void disconnect() {
              disconnected = true;
              retireBody();
            }

            Future<void> serve() async {
              try {
                expect(
                  headers,
                  contains('GET /film.iso?sig=%2f%2B&x=a+b&x=2 HTTP/1.1\r\n'),
                );
                String? header(String name) => RegExp(
                  '^$name: ([^\\r\\n]+)',
                  multiLine: true,
                  caseSensitive: false,
                ).firstMatch(headers)?[1];
                expect(header('x-emby-token'), null);
                expect(header('x-emby-authorization'), null);
                expect(header('accept-encoding'), 'identity');
                range = header('range')!;
                ranges.add(range);
                final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
                final start = int.parse(match[1]!);
                final bounded = match[2]!.isNotEmpty;
                final end = bounded ? int.parse(match[2]!) : total - 1;
                if (bounded) partRequests++;
                // Exercise identity/failure checks on the new continuous
                // reader's single permitted recovery, not removed side ranges.
                final resumed = start > 0;
                if (resumed) {
                  expect(header('if-match'), '"v1"');
                  if (variant == 'redirect') {
                    socket.write(
                      'HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:${origin.port}/film.iso\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
                    );
                    await socket.flush();
                    return;
                  }
                  if (variant == 'denied') {
                    socket.write(
                      'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
                    );
                    await socket.flush();
                    return;
                  }
                }
                active++;
                events.add(
                  '${timeline.elapsedMilliseconds} open $range active=$active',
                );
                counted = true;
                if (active > peak) peak = active;
                final tag = variant == 'weak'
                    ? 'W/"v1"'
                    : variant == 'changed' && resumed
                    ? '"v2"'
                    : '"v1"';
                socket.write(
                  'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes $start-$end/${variant == 'length' && resumed ? total + 1 : total}\r\nContent-Length: ${end - start + 1}\r\n${variant == 'missing' ? '' : 'ETag: $tag\r\n'}Connection: close\r\n\r\n',
                );
                for (var at = start; at <= end; at += 256 * 1024) {
                  if (disconnected) break;
                  if (at >= start + 2 * mib &&
                      (!resumed &&
                              ![
                                'strong',
                                'weak',
                                'missing',
                              ].contains(variant) ||
                          variant == 'cut_twice' && resumed)) {
                    break;
                  }
                  final count = (end - at + 1).clamp(0, 256 * 1024);
                  final bytes = Uint8List(count);
                  for (var i = 0; i < count;) {
                    final take = (256 * 1024 - (at + i) % (256 * 1024)).clamp(
                      0,
                      count - i,
                    );
                    bytes.fillRange(
                      i,
                      i + take,
                      ((at + i) ~/ (256 * 1024)) % 251,
                    );
                    i += take;
                  }
                  socket.add(bytes);
                  await socket.flush();
                  if (at + count > end) {
                    // The declared body is complete, even if an artificial timer
                    // would keep this Dart request handler alive for another tick.
                    retireBody();
                    break;
                  }
                  // Model a per-connection throughput cap, not the user's network.
                  await Future<void>.delayed(const Duration(milliseconds: 1));
                }
              } on SocketException {
                /* expected retirement/seek */
              } on HttpException {
                /* closed consumer */
              } finally {
                retireBody();
                try {
                  await socket.close();
                } catch (_) {}
              }
            }

            socket.listen(
              (data) {
                headers += latin1.decode(data);
                if (!handled && headers.contains('\r\n\r\n')) {
                  handled = true;
                  serveDone.add(serve());
                }
              },
              onDone: disconnect,
              onError: (Object _) => disconnect(),
            );
          });
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            (call) async => call.method == 'open' ? titleData : null,
          );
          final transport = DiscTransport(
            route(
              'http://127.0.0.1:${origin.port}/film.iso',
              origin: Uri.parse('http://127.0.0.1:${origin.port}'),
            ),
            kind: DiscKind.iso,
            cacheBytes: 16 * mib,
          );
          final client = HttpClient();
          try {
            await transport.start();
            transport.setSpeed(speed);
            final shouldFail = [
              'changed',
              'length',
              'redirect',
              'denied',
              'cut_twice',
            ].contains(variant);
            var failed = false;
            final measured = Stopwatch()..start();
            for (var at = 0; at < total; at += mib) {
              final request = await client.getUrl(
                Uri.parse('${transport.base}/input?path='),
              );
              request.headers.set('Range', 'bytes=$at-${at + mib - 1}');
              final response = await request.close();
              final builder = await response.fold(
                BytesBuilder(copy: false),
                (b, d) => b..add(d),
              );
              if (response.statusCode != 206) {
                failed = true;
                break;
              }
              final bytes = builder.takeBytes();
              expect(bytes.length, mib);
              for (var i = 0; i < mib; i += 256 * 1024) {
                expect(bytes[i], ((at + i) ~/ (256 * 1024)) % 251);
                expect(
                  bytes[i + 256 * 1024 - 1],
                  ((at + i) ~/ (256 * 1024)) % 251,
                );
              }
            }
            expect(failed, shouldFail);
            expect(entries, 1);
            if (variant == 'strong') {
              Directory('build').createSync(recursive: true);
              File('build/speed-http-strong.json').writeAsStringSync(
                jsonEncode({
                  'bytes': total,
                  'milliseconds': measured.elapsedMilliseconds,
                  'entry_requests': entries,
                  'media_requests': ranges.length,
                  'bounded_requests': partRequests,
                  'peak_media_bodies': peak,
                  'byte_order': 'verified',
                  'scope': 'synthetic local HTTP only',
                  'events': events,
                }),
              );
            }
            expect(peak, lessThanOrEqualTo(2));
            if (['strong', 'cut'].contains(variant)) {
              expect(partRequests, greaterThan(0));
              expect(ranges.length, greaterThan(2));
            } else if (['weak', 'missing'].contains(variant)) {
              expect(partRequests, 0);
              expect(ranges.length, 1);
            } else {
              expect(partRequests, 0);
              expect(ranges.length, 2);
            }
            if (shouldFail) {
              final count = ranges.length;
              final retry = await client.getUrl(
                Uri.parse('${transport.base}/input?path='),
              );
              retry.headers.set('Range', 'bytes=${60 * mib}-${61 * mib - 1}');
              await (await retry.close()).drain<void>();
              expect(
                ranges.length,
                count,
                reason: 'no retry storm after identity failure',
              );
            }
          } finally {
            client.close(force: true);
            await transport.close();
            await origin.close(force: true);
            await media.close();
            for (final socket in sockets) {
              socket.destroy();
            }
            await Future.wait(serveDone);
            binding.defaultBinaryMessenger.setMockMethodCallHandler(
              DiscTransport.channel,
              null,
            );
          }
        }, LoopbackHttpOverrides());
      },
    );
  }
}
