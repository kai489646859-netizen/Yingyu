import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'same-origin strong validator enables bounded reads and keeps account headers',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const mib = 1048576, total = 24 * mib + 57;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        var originals = 0, parts = 0;
        final jobs = <Future<void>>[];
        Future<void> serve(HttpRequest r) async {
          expect(r.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
          final range = discByteRange(r.headers.value('range'), total)!;
          final bounded = !r.headers.value('range')!.endsWith('-');
          if (range.start == 0) originals++;
          if (bounded) {
            parts++;
            expect(r.headers.value('if-match'), '"same"');
          }
          r.response.statusCode = 206;
          r.response.contentLength = range.end - range.start + 1;
          r.response.headers.set(
            'content-range',
            'bytes ${range.start}-${range.end}/$total',
          );
          r.response.headers.set('etag', '"same"');
          try {
            for (var at = range.start; at <= range.end;) {
              final n = (65536 - at % 65536).clamp(0, range.end - at + 1);
              r.response.add(Uint8List(n)..fillRange(0, n, at ~/ 65536 % 251));
              await r.response.flush();
              at += n;
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }
            await r.response.close();
          } on SocketException {
            /* expected cancellation */
          } on HttpException {
            /* expected cancellation */
          }
        }

        server.listen((r) {
          jobs.add(serve(r));
        });
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async => call.method == 'open' ? titleData : null,
        );
        final base = Uri.parse('http://127.0.0.1:${server.port}');
        final transport = DiscTransport(
          route('$base/film.iso', origin: base),
          kind: DiscKind.iso,
        )..setSpeed(3);
        final client = HttpClient();
        try {
          await transport.start();
          for (var at = 0; at < total;) {
            final n = (total - at).clamp(0, mib);
            final request = await client.getUrl(
              Uri.parse('${transport.base}/input?path='),
            );
            request.headers.set('range', 'bytes=$at-${at + n - 1}');
            final response = await request.close();
            expect(response.statusCode, 206);
            var read = 0;
            await for (final bytes in response) {
              for (var i = 0; i < bytes.length; i++) {
                if (bytes[i] != (at + read + i) ~/ 65536 % 251) {
                  fail('same-origin byte mismatch');
                }
              }
              read += bytes.length;
            }
            expect(read, n);
            at += read;
          }
          expect(originals, 1);
          expect(parts, greaterThan(0));
          expect(transport.failure, null);
          expect(transport.readHealth, contains('峰值媒体响应=2'));
        } finally {
          client.close(force: true);
          await transport.close();
          await server.close(force: true);
          await Future.wait(jobs);
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            null,
          );
        }
      }, LoopbackHttpOverrides());
    },
  );
}
