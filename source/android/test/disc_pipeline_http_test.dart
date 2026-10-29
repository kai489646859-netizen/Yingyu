import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in [DiscKind.iso, DiscKind.blurayFolder]) {
    test(
      '${kind.name} waits on one HTTP body across block boundaries and speed changes',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          const mib = 1024 * 1024, total = 16 * mib;
          final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final external = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final originBase = Uri.parse('http://127.0.0.1:${origin.port}');
          final stalled = Completer<void>(), release = Completer<void>();
          var entries = 0, media = 0;
          final served = <Future<void>>[];
          origin.listen((request) async {
            entries++;
            expect(request.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
            request.response.statusCode = 302;
            request.response.headers.set(
              'Location',
              'http://127.0.0.1:${external.port}${request.uri.path}?sig=synthetic',
            );
            await request.response.close();
          });
          Future<void> serve(HttpRequest request) async {
            expect(request.headers.value('x-emby-token'), null);
            expect(request.headers.value('x-emby-authorization'), null);
            final range = discByteRange(request.headers.value('range'), total)!;
            final metadata = request.uri.path.endsWith('index.bdmv');
            if (!metadata) {
              media++;
              expect(request.headers.value('range'), 'bytes=0-');
            }
            request.response.statusCode = 206;
            request.response.headers.set(
              'Content-Range',
              'bytes ${range.start}-${range.end}/$total',
            );
            request.response.contentLength = range.end - range.start + 1;
            for (var offset = range.start; offset <= range.end; offset += mib) {
              if (!metadata && offset == 4 * mib) {
                stalled.complete();
                await release.future;
              }
              final length = (range.end - offset + 1).clamp(0, mib);
              request.response.add(
                Uint8List(length)..fillRange(0, length, offset ~/ mib),
              );
              await request.response.flush();
            }
            await request.response.close();
          }

          external.listen((request) {
            final future = serve(request);
            served.add(future);
            unawaited(future.then<void>((_) {}, onError: (Object _) {}));
          });
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            (call) async => call.method == 'open' ? titleData : null,
          );
          final url =
              '$originBase/${kind == DiscKind.iso ? "film.iso" : "disc/BDMV/index.bdmv"}';
          final transport = DiscTransport(
            route(url, origin: originBase, kind: kind),
            kind: kind,
          );
          final client = HttpClient();
          Future<void> read(int offset) async {
            final path = kind == DiscKind.iso ? '' : 'BDMV/STREAM/00001.m2ts';
            final request = await client.getUrl(
              Uri.parse(
                '${transport.base}/input?path=${Uri.encodeComponent(path)}',
              ),
            );
            request.headers.set('Range', 'bytes=$offset-${offset + mib - 1}');
            final response = await request.close();
            expect(response.statusCode, 206);
            final data = await response.fold<BytesBuilder>(
              BytesBuilder(copy: false),
              (b, d) => b..add(d),
            );
            final bytes = data.takeBytes();
            expect(bytes.length, mib);
            expect(bytes.every((byte) => byte == offset ~/ mib), true);
          }

          Future<void>? demand;
          try {
            await transport.start();
            for (var offset = 0; offset < 4 * mib; offset += mib) {
              await read(offset);
            }
            await stalled.future.timeout(const Duration(seconds: 5));
            demand = read(4 * mib);
            unawaited(demand.then<void>((_) {}, onError: (Object _) {}));
            transport.setSpeed(3);
            await Future<void>.delayed(const Duration(milliseconds: 80));
            expect(
              media,
              1,
              reason: 'a slow body must not start another cloud request',
            );
            expect(entries, 1);
            release.complete();
            await demand;
            for (var offset = 5 * mib; offset < total; offset += mib) {
              await read(offset);
            }
            expect(media, 1);
            expect(entries, 1);
            expect(transport.readHealth, contains('连续媒体请求=1'));
            expect(transport.readHealth, contains('已供给=16.0 MiB'));
            expect(transport.failure, null);
          } finally {
            if (!release.isCompleted) release.complete();
            if (demand != null) {
              try {
                await demand;
              } catch (_) {}
            }
            client.close(force: true);
            await transport.close();
            await origin.close(force: true);
            await external.close(force: true);
            await Future.wait(served.map((f) => f.catchError((Object _) {})));
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
