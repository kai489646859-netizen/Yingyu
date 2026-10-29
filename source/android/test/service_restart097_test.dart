import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'origin_transport_test.dart' show route;
import 'core_test.dart' show LoopbackHttpOverrides;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'restart 502 remains real; a fresh attempt works when service is ready without playing another resource',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      var ready = false;
      final sub = server.listen((req) async {
        requests++;
        expect(req.headers.value('range'), 'bytes=0-');
        if (!ready) {
          req.response.statusCode = 502;
          req.response.headers.contentType = ContentType.html;
          req.response.write('<html>502 Bad Gateway</html>');
        } else {
          req.response.statusCode = 302;
          req.response.headers.set(
            'Location',
            'https://cdn.example.invalid/synthetic',
          );
        }
        await req.response.close();
      });
      final native = HttpClient();
      Future<HttpClientResponse> request(EmbyOriginTransport transport) async {
        final q = await native.getUrl(Uri.parse(await transport.start()));
        q.followRedirects = false;
        q.headers.set('Range', 'bytes=0-');
        return q.close();
      }

      try {
        for (var i = 0; i < 8; i++) {
          final transport = EmbyOriginTransport(
            route('http://127.0.0.1:${server.port}'),
          );
          try {
            final response = await request(transport);
            expect(response.statusCode, 502);
            await response.drain<void>();
            expect(transport.upstreamFailure, contains('HTTP 502'));
            expect(transport.upstreamFailure, contains('稍后重试'));
          } finally {
            await transport.close();
          }
        }
        expect(requests, 8);
        ready = true;
        final fresh = EmbyOriginTransport(
          route('http://127.0.0.1:${server.port}'),
        );
        try {
          final response = await request(fresh);
          expect(response.statusCode, 302);
          expect(
            response.headers.value('location'),
            'https://cdn.example.invalid/synthetic',
          );
          await response.drain<void>();
          expect(fresh.upstreamFailure, isNull);
        } finally {
          await fresh.close();
        }
        expect(requests, 9);
      } finally {
        native.close(force: true);
        await sub.cancel();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
