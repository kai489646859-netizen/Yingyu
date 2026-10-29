import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'package:yingyu/playback/disc_transport.dart' show ExactHttpUri;
import 'core_test.dart' show syntheticSession, LoopbackHttpOverrides;
import 'startup_test.dart' show sourceFor, detailFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final protocol in ['Http', 'https', 'File']) {
    test(
      'complete $protocol source opens static original despite blocked PlaybackInfo',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          var negotiations = 0, reads = 0;
          final gate = Completer<void>();
          final api = EmbyClient(
            client: MockClient((_) async {
              negotiations++;
              await gate.future;
              throw const SocketException('blocked PlaybackInfo');
            }),
          )..session = syntheticSession('http://127.0.0.1:${server.port}');
          server.listen((r) async {
            reads++;
            expect(r.uri.path, '/Videos/movie/stream.mp4');
            expect(r.uri.queryParameters['Static'], 'true');
            expect(r.uri.queryParameters['MediaSourceId'], 'source-1');
            expect(r.headers.value('range'), 'bytes=0-3');
            r.response.statusCode = 206;
            r.response.contentLength = 4;
            r.response.headers.set('content-range', 'bytes 0-3/4');
            r.response.add([1, 2, 3, 4]);
            await r.response.close();
          });
          final http = HttpClient();
          EmbyOriginTransport? origin;
          try {
            final route = await api
                .preparePlayback(
                  detailFor({
                    ...sourceFor('mp4'),
                    'Protocol': protocol,
                    'IsRemote': true,
                    'Path': 'https://server-only.invalid/private-original.mp4',
                  }),
                  start: const Duration(milliseconds: 497240),
                )
                .timeout(const Duration(milliseconds: 500));
            expect(negotiations, 0);
            expect(reads, 0, reason: 'route preparation must not probe media');
            expect(route.url, isNot(contains('server-only.invalid')));
            origin = EmbyOriginTransport(route);
            final address = await origin.start();
            final req = await http.getUrl(ExactHttpUri(address));
            req.headers.set('Range', 'bytes=0-3');
            final reply = await req.close().timeout(const Duration(seconds: 2));
            expect(reply.statusCode, 206);
            expect(await reply.fold<List<int>>([], (a, b) => a..addAll(b)), [
              1,
              2,
              3,
              4,
            ]);
            expect(reads, 1);
            expect(negotiations, 0);
          } finally {
            gate.complete();
            http.close(force: true);
            await origin?.close();
            api.close();
            await server.close(force: true);
          }
        }, LoopbackHttpOverrides());
      },
    );
  }
}
