import 'dart:convert';
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
    'real loopback socket interruption resumes external bytes without revisiting STRM or leaking account headers',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final media = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        var entries = 0, bodies = 0;
        final offsets = <int>[];
        const total = 128 * 1024, cut = 4096;
        final bytes = Uint8List.fromList(List.generate(total, (i) => i % 251));
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
          var headers = '', handled = false;
          socket.listen((data) async {
            headers += latin1.decode(data);
            if (handled || !headers.contains('\r\n\r\n')) return;
            handled = true;
            bodies++;
            expect(headers, contains('GET /film.iso?sig=%2f%2B&x=a+b&x=2 '));
            expect(headers.toLowerCase(), isNot(contains('x-emby')));
            final start = int.parse(
              RegExp(
                r'range: bytes=(\d+)-',
                caseSensitive: false,
              ).firstMatch(headers)![1]!,
            );
            offsets.add(start);
            socket.add(
              ascii.encode(
                'HTTP/1.1 206 Partial Content\r\nContent-Length: ${total - start}\r\nContent-Range: bytes $start-${total - 1}/$total\r\nETag: "fixture"\r\nConnection: close\r\n\r\n',
              ),
            );
            socket.add(bytes.sublist(start, bodies == 1 ? cut : total));
            await socket.flush();
            if (bodies == 1) {
              socket.destroy();
            } else {
              await socket.close();
            }
          }, onError: (Object _) {});
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
        );
        final client = HttpClient();
        try {
          await transport.start();
          final r = await client.getUrl(
            Uri.parse('${transport.base}/input?path='),
          );
          r.headers.set('Range', 'bytes=0-${total - 1}');
          final response = await r.close();
          expect(response.statusCode, 206);
          final received = await response
              .fold<BytesBuilder>(
                BytesBuilder(copy: false),
                (b, d) => b..add(d),
              )
              .timeout(const Duration(seconds: 10));
          expect(received.takeBytes(), bytes);
          expect(offsets, [0, cut]);
          expect(entries, 1);
          expect(bodies, 2);
          expect(transport.failure, null);
        } finally {
          client.close(force: true);
          await transport.close();
          await origin.close(force: true);
          await media.close();
          for (final socket in sockets) {
            socket.destroy();
          }
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            null,
          );
        }
      }, LoopbackHttpOverrides());
    },
  );
}
