import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/disc_worker.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in ['2x', '3x', 'seek']) {
    final speed = scenario == '2x' ? 2.0 : 3.0;
    test(
      'real Dart input -> Java native substitute -> background HTTP $scenario',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          const mib = 1024 * 1024, total = 64 * mib;
          final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          var entries = 0, sourceRequests = 0, channelReads = 0;
          final work = <Future<void>>[];
          origin.listen((request) async {
            entries++;
            expect(request.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
            request.response.statusCode = 302;
            request.response.headers.set(
              'location',
              'http://127.0.0.1:${media.port}/film.iso?sig=synthetic',
            );
            await request.response.close();
          });
          Future<void> serve(HttpRequest request) async {
            sourceRequests++;
            expect(request.headers.value('x-emby-token'), null);
            expect(request.headers.value('x-emby-authorization'), null);
            final range = discByteRange(request.headers.value('range'), total)!;
            request.response.statusCode = 206;
            request.response.headers.set(
              'Content-Range',
              'bytes ${range.start}-${range.end}/$total',
            );
            request.response.headers.set('etag', '"synthetic-stable"');
            request.response.contentLength = range.end - range.start + 1;
            try {
              for (var at = range.start; at <= range.end; at += mib) {
                final count = (range.end - at + 1).clamp(0, mib);
                final bytes = Uint8List(count);
                for (var i = 0; i < count;) {
                  final take = (mib - (at + i) % mib).clamp(0, count - i);
                  bytes.fillRange(i, i + take, (at + i) ~/ mib % 251);
                  i += take;
                }
                request.response.add(bytes);
                await request.response.flush();
              }
              await request.response.close();
            } on SocketException {
              /* cancelled speculative bytes */
            } on HttpException {
              /* cancelled speculative bytes */
            }
          }

          media.listen((request) {
            final result = serve(request);
            work.add(result);
            unawaited(result.catchError((Object _) {}));
          });
          Process? java;
          StreamIterator<String>? replies;
          Future<void> statusTail = Future.value();
          Json? ready;
          String javaErrors = '';
          Future<Json> status() {
            final result = statusTail.then((_) async {
              java!.stdin.writeln('status');
              expect(
                await replies!.moveNext().timeout(const Duration(seconds: 5)),
                true,
              );
              return object(jsonDecode(replies!.current));
            });
            statusTail = result.then<void>((_) {}, onError: (Object _) {});
            return result;
          }

          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            (call) async {
              final args = call.arguments as Map;
              if (call.method == 'open') {
                final home = Platform.environment['JAVA_HOME']!;
                final work =
                    Platform.environment['YINGYU_BUILD_HOME'] ??
                    '${Platform.environment['LOCALAPPDATA']}/YingyuFreshBuild';
                java = await Process.start('$home/bin/java.exe', [
                  '-Dfile.encoding=UTF-8',
                  '-cp',
                  '$work/disc-host-tests/classes',
                  'com.yingyu.player.DiscLoopbackHarness',
                  args['base'] as String,
                  args['id'] as String,
                  '$total',
                ]);
                java!.stderr
                    .transform(utf8.decoder)
                    .listen((value) => javaErrors += value);
                replies = StreamIterator(
                  java!.stdout
                      .transform(utf8.decoder)
                      .transform(const LineSplitter()),
                );
                expect(
                  await replies!.moveNext().timeout(const Duration(seconds: 5)),
                  true,
                );
                ready = object(jsonDecode(replies!.current));
                return ready!['titles'];
              }
              if (call.method == 'output') return ready!['output'];
              if (call.method == 'outputStatus') return status();
              if (call.method == 'read') {
                channelReads++;
                throw StateError('media bytes crossed Flutter');
              }
              return null;
            },
          );
          final transport = DiscWorkerTransport(
            route(
              'http://127.0.0.1:${origin.port}/film.iso',
              origin: Uri.parse('http://127.0.0.1:${origin.port}'),
            ),
            kind: DiscKind.iso,
          );
          final client = HttpClient();
          try {
            await transport.start();
            transport.setSpeed(speed);
            final address = Uri.parse('${ready!['output']}/clip/00001.m2ts');
            if (scenario == 'seek') {
              // Abandon partial output bodies, then seek forward and backward.
              // Reset before the replacement, as the real backend does.
              for (final offset in [0, 40 * mib, 2 * mib]) {
                transport.resetReadAhead();
                final request = await client.getUrl(address);
                request.headers.set('range', 'bytes=$offset-');
                final response = await request.close();
                expect(response.statusCode, 206);
                var read = 0;
                await for (final bytes in response) {
                  for (var i = 0; i < bytes.length; i++) {
                    if (bytes[i] != (offset + read + i) ~/ mib % 251) {
                      fail('seek changed bytes');
                    }
                  }
                  read += bytes.length;
                  if (read >= mib) break;
                }
                transport.setSpeed(2);
                transport.setSpeed(3);
                expect((await status())['failed'], false);
              }
              final snapshot = await status();
              expect(snapshot['requests'], 3);
              expect(channelReads, 0);
              expect(entries, 1);
              expect(transport.failure, null);
              return;
            }
            final measured = Stopwatch()..start();
            final request = await client.getUrl(address);
            final response = await request.close();
            expect(response.statusCode, 200);
            expect(response.contentLength, total);
            var count = 0;
            await for (final bytes in response) {
              for (var i = 0; i < bytes.length; i++) {
                if (bytes[i] != (count + i) ~/ mib % 251) {
                  fail('body order changed at ${count + i}');
                }
              }
              count += bytes.length;
              // Temporary 3x release to 2x and back uses the same producer.
              if (count >= 16 * mib && count < 17 * mib) transport.setSpeed(2);
              if (count >= 32 * mib && count < 33 * mib) {
                transport.setSpeed(speed);
              }
            }
            measured.stop();
            expect(count, total);
            expect(channelReads, 0);
            expect(entries, 1);
            expect(sourceRequests, greaterThan(1));
            await transport.refreshReadHealth();
            expect(transport.readHealth, contains('峰值媒体响应=2'));
            final snapshot = await status();
            expect(snapshot['failed'], false);
            expect(transport.failure, null);
            final result = {
              'speed': speed,
              'bytes': count,
              'wall_ms': measured.elapsedMilliseconds,
              'host_MB_s': count / measured.elapsedMicroseconds,
              'flutter_byte_calls': channelReads,
              'entry_requests': entries,
              'source_requests': sourceRequests,
              'java_status': snapshot,
              'io_isolate': true,
              'scope':
                  'Windows host synthetic HTTP/Java JNI substitute; no Android, real ISO, MPV or decoding.',
            };
            Directory('build').createSync(recursive: true);
            File(
              'build/background-chain-${speed.toInt()}.json',
            ).writeAsStringSync(jsonEncode(result));
          } finally {
            client.close(force: true);
            await transport.close();
            await statusTail;
            final process = java;
            if (process != null) {
              process.stdin.writeln('close');
              await process.stdin.close();
              try {
                expect(
                  await process.exitCode.timeout(const Duration(seconds: 5)),
                  0,
                  reason: javaErrors,
                );
              } on TimeoutException {
                process.kill();
                await process.exitCode;
                fail('Java bridge did not close');
              }
            }
            await replies?.cancel();
            await origin.close(force: true);
            await media.close(force: true);
            await Future.wait(work);
            binding.defaultBinaryMessenger.setMockMethodCallHandler(
              DiscTransport.channel,
              null,
            );
          }
        }, LoopbackHttpOverrides());
      },
      timeout: const Timeout(Duration(seconds: 45)),
    );
  }
}
