import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/first_hop_probe.dart';
import 'core_test.dart' show LoopbackHttpOverrides;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed-route comparison never follows redirects or records credentials',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var originReads = 0, mediaReads = 0;
      final authenticated = <bool>[];
      final sub = origin.listen((request) async {
        originReads++;
        authenticated.add(request.headers.value('X-Emby-Token') != null);
        expect(request.headers.value('Range'), 'bytes=0-0');
        expect(request.headers.value('User-Agent'), 'test-agent');
        if (request.uri.path == '/original' && !authenticated.last) {
          request.response.statusCode = 403;
          request.response.headers.set('Server', 'nginx/PRIVATE');
          request.response.write(
            '{"ResponseStatus":{"ErrorCode":"SecurityException",'
            '"Message":"Emby Premiere required for client PRIVATE_TOKEN https://secret.invalid/file"}}',
          );
        } else {
          request.response.statusCode = 302;
          request.response.headers.set(
            'Location',
            'http://127.0.0.1:${media.port}/single-use?token=PRIVATE_TOKEN',
          );
        }
        await request.response.close();
      });
      final mediaSub = media.listen((request) async {
        mediaReads++;
        await request.response.close();
      });
      final log = DiagnosticLog();
      final base = 'http://127.0.0.1:${origin.port}';
      try {
        await inspectRejectedRoute(
          PlaybackRoute(
            url: '$base/original?api_key=PRIVATE_TOKEN',
            diagnosticCanonicalUrl: '$base/canonical?api_key=PRIVATE_TOKEN',
            serverBase: Uri.parse(base),
            sourceId: 'synthetic',
            sessionId: 'synthetic',
            headers: {'User-Agent': 'test-agent'},
            diagnosticSecrets: ['PRIVATE_TOKEN', 'PRIVATE'],
            streams: [],
          ),
          log,
          embyHeaders: {'X-Emby-Token': 'SYNTHETIC_TOKEN'},
        );
        expect(originReads, 3);
        expect(authenticated, [false, false, true]);
        expect(mediaReads, 0);
        expect(log.export(), contains('HTTP 403'));
        expect(log.export(), contains('HTTP 302'));
        expect(log.export(), contains('Emby Premiere required for client'));
        expect(log.export(), contains('SecurityException'));
        expect(log.export(), isNot(contains('PRIVATE')));
        expect(log.export(), isNot(contains('secret.invalid')));
      } finally {
        await sub.cancel();
        await mediaSub.cancel();
        await origin.close(force: true);
        await media.close(force: true);
        log.dispose();
      }
    }, LoopbackHttpOverrides()),
  );
}
