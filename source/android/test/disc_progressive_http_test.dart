import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

const _mib = 1024 * 1024;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final speed in [2.0, 3.0]) {
    for (final target in [0, 12 * _mib]) {
      test(
        '$speed x input receives needed MiB before block tail at $target',
        () async {
          await HttpOverrides.runWithHttpOverrides(() async {
            final origin = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final media = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final tail = Completer<void>(), prefixSent = Completer<void>();
            final handlers = <Future<void>>[];
            var entries = 0;
            const total = 64 * _mib;
            origin.listen((r) async {
              entries++;
              r.response.statusCode = 302;
              r.response.headers.set(
                'Location',
                'http://127.0.0.1:${media.port}/disc.iso',
              );
              await r.response.close();
            });
            Future<void> serve(HttpRequest r) async {
              try {
                expect(r.headers.value('x-emby-token'), isNull);
                final range = RegExp(
                  r'bytes=(\d+)-(\d*)',
                ).firstMatch(r.headers.value('range')!)!;
                final start = int.parse(range[1]!);
                final end = range[2]!.isEmpty
                    ? total - 1
                    : int.parse(range[2]!);
                r.response.statusCode = 206;
                r.response.headers.set(
                  'Content-Range',
                  'bytes $start-$end/$total',
                );
                r.response.headers.set('ETag', '"progressive-v1"');
                r.response.contentLength = end - start + 1;
                for (var at = start; at <= end; at += _mib) {
                  if (at == target + _mib && start <= target) {
                    if (!prefixSent.isCompleted) prefixSent.complete();
                    await tail.future;
                  }
                  final count = (end - at + 1).clamp(0, _mib);
                  r.response.add(
                    Uint8List(count)..fillRange(0, count, at ~/ _mib),
                  );
                  await r.response.flush();
                }
                await r.response.close();
              } on SocketException {
                // A seek, handoff or close legitimately retires a response.
              } on HttpException {
                // A retired consumer must not keep this fixture alive.
              }
            }

            media.listen((r) => handlers.add(serve(r)));
            binding.defaultBinaryMessenger.setMockMethodCallHandler(
              DiscTransport.channel,
              (call) async => call.method == 'open' ? titleData : null,
            );
            final transport = DiscTransport(
              route(
                'http://127.0.0.1:${origin.port}/disc.iso',
                origin: Uri.parse('http://127.0.0.1:${origin.port}'),
              ),
              kind: DiscKind.iso,
            );
            final client = HttpClient();
            Future<Uint8List> read(int at) async {
              final request = await client.getUrl(
                Uri.parse('${transport.base}/input?path='),
              );
              request.headers.set('Range', 'bytes=$at-${at + _mib - 1}');
              final response = await request.close();
              expect(response.statusCode, 206);
              return (await response.fold(
                BytesBuilder(copy: false),
                (b, d) => b..add(d),
              )).takeBytes();
            }

            try {
              await transport.start();
              transport.setSpeed(speed);
              for (var at = 0; at < target; at += _mib) {
                final bytes = await read(at);
                expect(bytes.length, _mib);
                expect(bytes.every((v) => v == at ~/ _mib), isTrue);
              }
              final requested = read(target);
              await prefixSent.future.timeout(const Duration(seconds: 8));
              final arrivedBeforeTail = await Future.any([
                requested.then((_) => true),
                Future<bool>.delayed(
                  const Duration(milliseconds: 500),
                  () => false,
                ),
              ]);
              tail.complete();
              final bytes = await requested;
              expect(bytes.length, _mib);
              expect(bytes.every((v) => v == target ~/ _mib), isTrue);
              expect(entries, 1);
              expect(
                arrivedBeforeTail,
                isTrue,
                reason:
                    'The needed MiB arrived; an unrelated block tail must not delay its delivery.',
              );
            } finally {
              if (!tail.isCompleted) tail.complete();
              await transport.close();
              client.close(force: true);
              await origin.close(force: true);
              await media.close(force: true);
              await Future.wait(handlers);
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
}
