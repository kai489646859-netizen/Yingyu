import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'core_test.dart'
    show LoopbackHttpOverrides, syntheticSession, playbackData;

PlaybackRoute route(
  String base, {
  String path = '/emby/Videos/1/stream',
}) => PlaybackRoute(
  url: '$base$path?api_key=SYNTHETIC_TOKEN&Static=true',
  sourceId: 'source',
  sessionId: 'session',
  headers: {'User-Agent': 'Yingyu-test'},
  streams: [],
  diagnosticSecrets: [
    'SYNTHETIC_TOKEN',
    'SYNTHETIC_USER',
    'SECRET_ACCOUNT',
    'SECRET',
  ],
  serverBase: Uri.parse('$base/emby'),
  sameOriginHeaders: {
    'X-Emby-Token': 'SYNTHETIC_TOKEN',
    'X-Emby-Authorization':
        'Emby Client="Yingyu", Device="Android", DeviceId="TEST", Version="0.0.3", UserId="SYNTHETIC_USER"',
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'server rejects token-only identity and accepts current user in same-origin header',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}/emby';
      final account = syntheticSession(base);
      final log = DiagnosticLog();
      final api = EmbyClient(log: log)..session = account;
      final native = HttpClient();
      EmbyOriginTransport? transport;
      final sub = server.listen((request) async {
        expect(request.headers.value('X-Emby-Token'), account.token);
        final hasUser = (request.headers.value('X-Emby-Authorization') ?? '')
            .contains('UserId="${account.userId}"');
        if (request.uri.path.endsWith('PlaybackInfo')) {
          expect(hasUser, true);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              playbackData(
                url:
                    '$base/Videos/test/stream?api_key=SYNTHETIC_TOKEN&Static=true',
              ),
            ),
          );
        } else if (!hasUser) {
          request.response.statusCode = 403;
          request.response.write(
            jsonEncode({
              'error': '播放被拒绝：请求中缺少 Emby User ID，无法确认播放用户。',
              'success': false,
            }),
          );
        } else {
          request.response.statusCode = 206;
          request.response.contentLength = 4;
          request.response.headers.set('Content-Range', 'bytes 0-3/4');
          request.response.add([1, 2, 3, 4]);
        }
        await request.response.close();
      });
      try {
        final missing = await native.getUrl(
          Uri.parse('$base/Videos/test/stream'),
        );
        api
            .headers(account.deviceId, token: account.token)
            .forEach(missing.headers.set);
        final rejected = await missing.close();
        expect(rejected.statusCode, 403);
        await rejected.drain<void>();
        final selected = await api.playback(MediaItem({'Id': 'test'}));
        expect(
          selected.sameOriginHeaders['X-Emby-Authorization'],
          contains('UserId="${account.userId}"'),
        );
        expect(
          selected.headers.keys.any(
            (key) => key.toLowerCase().startsWith('x-emby-'),
          ),
          false,
        );
        expect(
          Uri.parse(selected.url).queryParameters.containsKey('UserId'),
          false,
        );
        transport = EmbyOriginTransport(selected, log: log);
        final get = await native.getUrl(Uri.parse(await transport.start()));
        get.headers.set('Range', 'bytes=0-3');
        final success = await get.close();
        expect(success.statusCode, 206);
        expect(await success.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
          4,
        ]);
        expect(log.export(), contains('身份头含用户 ID=有'));
        expect(log.export(), isNot(contains(account.userId)));
        expect(log.export(), isNot(contains(account.token)));
      } finally {
        await transport?.close();
        api.close();
        native.close(force: true);
        log.dispose();
        await sub.cancel();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'origin authentication restores rejected stream and preserves seeking without preflight',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      var requests = 0;
      final ranges = <String?>[];
      final sub = server.listen((req) async {
        requests++;
        ranges.add(req.headers.value('range'));
        if (req.headers.value('X-Emby-Token') != 'SYNTHETIC_TOKEN') {
          req.response.statusCode = 403;
        } else {
          expect(
            req.headers.value('X-Emby-Authorization'),
            contains('DeviceId="TEST"'),
          );
          expect(req.headers.value('User-Agent'), 'Yingyu-test');
          final start = req.headers.value('range') == 'bytes=4-7' ? 4 : 0;
          req.response.statusCode = 206;
          req.response.headers.set(
            'Content-Range',
            'bytes $start-${start + 3}/8',
          );
          req.response.contentLength = 4;
          req.response.add(List.generate(4, (i) => start + i));
        }
        await req.response.close();
      });
      final native = HttpClient();
      final transport = EmbyOriginTransport(route(base));
      try {
        final before = await (await native.getUrl(
          Uri.parse(route(base).url),
        )).close();
        expect(before.statusCode, 403);
        await before.drain<void>();
        final address = Uri.parse(await transport.start());
        expect(requests, 1, reason: 'starting the bridge must not fetch media');
        for (final start in [0, 4]) {
          final req = await native.getUrl(address);
          req.headers.set('Range', 'bytes=$start-${start + 3}');
          final response = await req.close();
          expect(response.statusCode, 206);
          expect(
            response.headers.value('content-range'),
            'bytes $start-${start + 3}/8',
          );
          expect(
            await response.fold<List<int>>([], (a, b) => a..addAll(b)),
            List.generate(4, (i) => start + i),
          );
        }
        expect(requests, 3);
        expect(ranges, [null, 'bytes=0-3', 'bytes=4-7']);
        final unknown = await (await native.getUrl(
          address.replace(path: '/unknown'),
        )).close();
        expect(unknown.statusCode, 404);
        await unknown.drain<void>();
        expect(requests, 3);
      } finally {
        await transport.close();
        native.close(force: true);
        await sub.cancel();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );

  test(
    'same-origin redirect authenticated; external signed redirect unmodified and untouched',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cloud = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${server.port}';
      final signed =
          'http://127.0.0.1:${cloud.port}/one?sign=a%2fb%2Bc&literal=%41&x=1&x=2';
      var originReads = 0, cloudReads = 0;
      final sub = server.listen((req) async {
        originReads++;
        expect(req.headers.value('X-Emby-Token'), 'SYNTHETIC_TOKEN');
        req.response.statusCode = 302;
        req.response.headers.set(
          'Location',
          req.uri.path.endsWith('/stream') ? '/resolve' : signed,
        );
        await req.response.close();
      });
      final cloudSub = cloud.listen((req) async {
        cloudReads++;
        expect(req.headers.value('X-Emby-Token'), isNull);
        expect(req.headers.value('X-Emby-Authorization'), isNull);
        expect(req.uri.queryParameters.containsKey('api_key'), false);
        expect(req.headers.value('Range'), 'bytes=0-3');
        req.response.statusCode = 206;
        req.response.add([1, 2, 3, 4]);
        await req.response.close();
      });
      final native = HttpClient();
      final log = DiagnosticLog();
      final transport = EmbyOriginTransport(route(base), log: log);
      try {
        final address = Uri.parse(await transport.start());
        final request = await native.getUrl(address);
        request.followRedirects = false;
        final response = await request.close();
        expect(response.statusCode, 302);
        expect(response.headers.value('Location'), signed);
        await response.drain<void>();
        expect(originReads, 2);
        expect(cloudReads, 0);
        // MPV may concurrently retry GET/HEAD or reopen its loopback URL on
        // seek. All of those must reuse the exact same resolved Location.
        await Future.wait(
          List.generate(6, (i) async {
            final again = await native.openUrl(
              i.isEven ? 'HEAD' : 'GET',
              address,
            );
            again.followRedirects = false;
            again.headers.set('Range', 'bytes=${i * 4}-');
            final cached = await again.close();
            expect(cached.statusCode, 302);
            expect(cached.headers.value('Location'), signed);
            await cached.drain<void>();
          }),
        );
        expect(
          originReads,
          2,
          reason: 'each hop of the initial resolution is visited once',
        );
        expect(cloudReads, 0, reason: 'no preflight against external media');
        final media = await native.getUrl(Uri.parse(signed));
        route(base).headers.forEach(media.headers.set);
        media.headers.set('Range', 'bytes=0-3');
        final bytes = await media.close();
        expect(await bytes.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
          4,
        ]);
        expect(cloudReads, 1);
        expect(log.export(), isNot(contains('SYNTHETIC_TOKEN')));
        expect(log.export(), isNot(contains('127.0.0.1')));
      } finally {
        await transport.close();
        native.close(force: true);
        log.dispose();
        await sub.cancel();
        await cloudSub.cancel();
        await server.close(force: true);
        await cloud.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );

  test(
    'server rejection status retained with only allowlisted JSON diagnosis',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sub = server.listen((req) async {
        req.response.statusCode = 403;
        req.response.write(
          '{"ResponseStatus":{"ErrorCode":"SecurityException",'
          '"Message":"Emby Premiere required for client SECRET_ACCOUNT https://private.invalid/?token=SECRET"}}',
        );
        await req.response.close();
      });
      final log = DiagnosticLog();
      final transport = EmbyOriginTransport(
        route('http://127.0.0.1:${server.port}'),
        log: log,
      );
      final native = HttpClient();
      try {
        final response = await (await native.getUrl(
          Uri.parse(await transport.start()),
        )).close();
        expect(response.statusCode, 403);
        await response.drain<void>();
        expect(
          transport.rejection,
          contains('Emby Premiere required for client'),
        );
        expect(transport.rejection, contains('SecurityException'));
        expect(log.export(), contains('认证令牌头=有；客户端身份头=有'));
        expect(log.export(), contains('错误正文：'));
        expect(log.export(), contains('完整；格式=JSON'));
        expect(log.export(), contains('响应头耗时='));
        expect(log.export(), isNot(contains('SECRET')));
        expect(log.export(), isNot(contains('private.invalid')));
      } finally {
        await transport.close();
        native.close(force: true);
        log.dispose();
        await sub.cancel();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );

  test(
    'closing transport aborts an unfinished media response',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final began = Completer<void>();
      final sub = server.listen((req) async {
        req.response.contentLength = 1000000;
        req.response.add([1]);
        await req.response.flush();
        began.complete();
      });
      final transport = EmbyOriginTransport(
        route('http://127.0.0.1:${server.port}'),
      );
      final native = HttpClient();
      try {
        final opening = (await native.getUrl(
          Uri.parse(await transport.start()),
        )).close();
        await began.future.timeout(const Duration(seconds: 2));
        await transport.close().timeout(const Duration(seconds: 2));
        try {
          await (await opening).drain<void>().timeout(
            const Duration(seconds: 2),
          );
        } on HttpException {
          /* Expected truncated body on cancellation. */
        } on SocketException {
          /* Opening may still be waiting for headers. */
        }
      } finally {
        await transport.close();
        native.close(force: true);
        await sub.cancel();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
