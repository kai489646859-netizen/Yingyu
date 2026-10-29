import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/version.dart';

http.Response response(
  String body,
  int status, {
  Map<String, String>? headers,
}) => http.Response(
  body,
  status,
  headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
);

class LoopbackHttpOverrides extends HttpOverrides {}

Session syntheticSession([String base = 'http://127.0.0.1:9/proxy/emby']) =>
    Session(
      base: Uri.parse(base),
      userId: 'synthetic-user',
      token: 'SYNTHETIC_TOKEN',
      username: '合成账户',
      deviceId: 'Yingyu-Android-test',
    );
Json playbackData({String? url, Json headers = const {}}) => {
  'PlaySessionId': 'synthetic-play',
  'MediaSources': [
    {
      'Id': 'source-1',
      'DirectStreamUrl': ?url,
      'RequiredHttpHeaders': headers,
      'MediaStreams': [],
    },
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('base path preserves reverse proxy and avoids duplicate emby', () {
    expect(
      normalizeServer('server.example:8096').toString(),
      'http://server.example:8096/emby',
    );
    expect(
      normalizeServer('https://server.example/proxy/emby/').path,
      '/proxy/emby',
    );
    expect(normalizeServer('https://server.example/proxy').path, '/proxy/emby');
    expect(
      () => normalizeServer('https://user:secret@server.example'),
      throwsA(isA<AppFailure>()),
    );
  });
  test('relative media and subtitle paths retain the server prefix', () {
    final base = Uri.parse('https://server.invalid/proxy/emby');
    expect(
      resolveMediaUri(base, 'Videos/id/Subtitles/0/Stream.srt').path,
      '/proxy/emby/Videos/id/Subtitles/0/Stream.srt',
    );
    expect(
      resolveMediaUri(base, '/signed/file?sig=a%2Fb').toString(),
      'https://server.invalid/signed/file?sig=a%2Fb',
    );
    expect(
      resolveMediaUri(base, '//cdn.invalid/a').toString(),
      'https://cdn.invalid/a',
    );
  });
  test(
    'synthetic login uses ASCII authorization and never persists password',
    () async {
      late http.Request captured;
      final client = EmbyClient(
        client: MockClient((req) async {
          captured = req;
          return response(
            jsonEncode({
              'AccessToken': 'SYNTHETIC_TOKEN',
              'User': {'Id': 'u', 'Name': '合成'},
            }),
            200,
          );
        }),
      );
      final account = await client.login(
        'http://127.0.0.1:9',
        '合成',
        'synthetic-password',
        'Yingyu-Android-device',
      );
      expect(
        captured.headers['X-Emby-Authorization']!.codeUnits.every(
          (c) => c <= 127,
        ),
        isTrue,
      );
      expect(jsonDecode(captured.body)['Pw'], 'synthetic-password');
      expect(
        captured.headers['X-Emby-Authorization'],
        isNot(contains('UserId=')),
      );
      expect(account.encode(), isNot(contains('synthetic-password')));
      client.close();
    },
  );
  test(
    'pagination search and episode offsets use bounded server queries',
    () async {
      final requests = <http.Request>[];
      final api = EmbyClient(
        client: MockClient((req) async {
          requests.add(req);
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      )..session = syntheticSession();
      await api.items(parent: 'library', search: '电影', start: 48);
      await api.episodes('series', 'season', start: 96);
      expect(requests[0].url.queryParameters, containsPair('Limit', '48'));
      expect(requests[0].url.queryParameters, containsPair('SearchTerm', '电影'));
      expect(requests[1].url.queryParameters, containsPair('StartIndex', '96'));
      api.close();
    },
  );
  test(
    'static original stream retains device/source/session; no preflight',
    () async {
      final requests = <http.Request>[];
      final api = EmbyClient(
        client: MockClient((req) async {
          requests.add(req);
          return response(jsonEncode(playbackData()), 200);
        }),
      )..session = syntheticSession();
      final route = await api.playback(MediaItem({'Id': 'movie'}));
      final uri = Uri.parse(route.url);
      expect(uri.path, '/proxy/emby/Videos/movie/stream');
      expect(uri.queryParameters, containsPair('Static', 'true'));
      expect(
        uri.queryParameters,
        containsPair('DeviceId', 'Yingyu-Android-test'),
      );
      expect(uri.queryParameters, containsPair('MediaSourceId', 'source-1'));
      expect(
        uri.queryParameters,
        containsPair('PlaySessionId', 'synthetic-play'),
      );
      expect(requests.length, 1);
      expect(jsonDecode(requests.single.body)['EnableTranscoding'], false);
      expect(route.headers, {'User-Agent': playbackUserAgent});
      api.close();
    },
  );
  test(
    'external signed URL stays byte-identical, only server-required media headers',
    () async {
      const signed =
          'https://media.example.invalid/file.mkv?sig=a%2Fb%2Bc&x=1&x=2&expires=1';
      final api = EmbyClient(
        client: MockClient(
          (_) async => response(
            jsonEncode(
              playbackData(
                url: signed,
                headers: {
                  'User-Agent': 'SyntheticMedia',
                  'Referer': 'https://source.example.invalid/',
                  'X-Emby-Token': 'SYNTHETIC_TOKEN',
                },
              ),
            ),
            200,
          ),
        ),
      )..session = syntheticSession();
      final route = await api.playback(MediaItem({'Id': 'movie'}));
      expect(route.url, signed);
      expect(route.headers, {
        'User-Agent': 'SyntheticMedia',
        'Referer': 'https://source.example.invalid/',
      });
      api.close();
    },
  );
  for (final code in [401, 403, 404, 500]) {
    test('HTTP $code remains a real visible failure', () async {
      var expired = false;
      final api =
          EmbyClient(
              client: MockClient(
                (_) async => response('secret-error-body', code),
              ),
            )
            ..session = syntheticSession()
            ..onUnauthorized = () => expired = true;
      await expectLater(
        api.detail('movie'),
        throwsA(isA<AppFailure>().having((e) => e.status, 'status', code)),
      );
      expect(expired, code == 401);
      api.close();
    });
  }
  test(
    'API redirects do not forward account credentials to a different endpoint',
    () async {
      var count = 0;
      final api = EmbyClient(
        client: MockClient((_) async {
          count++;
          return response(
            '',
            302,
            headers: {'location': 'https://other.invalid/'},
          );
        }),
      )..session = syntheticSession();
      await expectLater(api.validate(), throwsA(isA<AppFailure>()));
      expect(count, 1);
      api.close();
    },
  );
  test(
    'timeouts and malformed server pages end loading with explicit failure',
    () async {
      final slow = EmbyClient(
        client: MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return response('{}', 200);
        }),
        timeout: const Duration(milliseconds: 10),
      )..session = syntheticSession();
      await expectLater(slow.validate(), throwsA(isA<AppFailure>()));
      slow.close();
      final html = EmbyClient(
        client: MockClient((_) async => response('<html>error</html>', 200)),
      )..session = syntheticSession();
      await expectLater(html.validate(), throwsA(isA<AppFailure>()));
      html.close();
    },
  );
  test(
    'legacy account and exact device identity copied using synthetic preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'emby_server_url': 'https://synthetic.invalid/proxy',
        'emby_access_token': 'SYNTHETIC_TOKEN',
        'emby_user_id': 'u',
        'emby_username': '合成',
        'media_server_device_id_generated_v1': 'device-1',
        'unrelated.setting': 'keep',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      final account = await store.loadSession();
      expect(account!.deviceId, 'Yingyu-Android-device-1');
      expect(account.base.path, '/proxy/emby');
      expect(prefs.getString('unrelated.setting'), 'keep');
      await store.clearSession();
      expect(await store.loadSession(), isNull);
      expect(prefs.getString('emby_access_token'), 'SYNTHETIC_TOKEN');
    },
  );
  test(
    'pending progress scoped by server and user, cleared only after matching sync',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final a = syntheticSession(),
          b = syntheticSession('http://127.0.0.1:10/emby');
      await store.saveProgress(a, 'movie', const Duration(seconds: 35));
      expect(store.localProgress(b, 'movie'), isNull);
      await store.confirmProgress(a, 'movie', const Duration(seconds: 30));
      expect(store.localProgress(a, 'movie'), const Duration(seconds: 35));
      await store.confirmProgress(a, 'movie', const Duration(seconds: 35));
      expect(store.localProgress(a, 'movie'), isNull);
    },
  );
  test(
    'failure redaction preserves HTTP status and removes signed credentials',
    () {
      expect(
        safeError(
          'HTTP 403 https://host.invalid/a?api_key=SECRET&x=Y DeviceId=private',
        ),
        allOf(
          contains('403'),
          isNot(contains('SECRET')),
          isNot(contains('private')),
        ),
      );
    },
  );
  test(
    'real loopback login → playback info → 302 → one-use range data (HTTP only, no MPV)',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var mediaRequests = 0, bytesRequests = 0;
      final base = 'http://127.0.0.1:${server.port}';
      final sub = server.listen((request) async {
        if (request.uri.path.endsWith('AuthenticateByName')) {
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          expect(body['Username'], '合成');
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'AccessToken': 'SYNTHETIC_TOKEN',
              'User': {'Id': 'user', 'Name': '合成'},
            }),
          );
        } else if (request.uri.path.endsWith('PlaybackInfo')) {
          expect(request.headers.value('X-Emby-Token'), 'SYNTHETIC_TOKEN');
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(playbackData()));
        } else if (request.uri.path.endsWith('/stream')) {
          mediaRequests++;
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            '$base/signed?sig=synthetic',
          );
        } else if (request.uri.path == '/signed') {
          bytesRequests++;
          expect(request.headers.value('X-Emby-Token'), isNull);
          request.response.statusCode = bytesRequests == 1 ? 206 : 403;
          request.response.add([1, 2, 3, 4]);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final api = EmbyClient();
      try {
        await api.login(base, '合成', 'synthetic', 'device');
        final route = await api.playback(MediaItem({'Id': 'movie'}));
        expect(mediaRequests, 0);
        expect(bytesRequests, 0);
        final transfer = HttpClient();
        try {
          final req = await transfer.getUrl(Uri.parse(route.url));
          req.headers.set('Range', 'bytes=0-3');
          final res = await req.close();
          expect(res.statusCode, 206);
          expect(await res.fold<List<int>>([], (a, b) => a..addAll(b)), [
            1,
            2,
            3,
            4,
          ]);
        } finally {
          transfer.close(force: true);
        }
        expect(bytesRequests, 1);
      } finally {
        api.close();
        await sub.cancel();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
