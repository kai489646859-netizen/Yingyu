import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart'
    show syntheticSession, playbackData, response, LoopbackHttpOverrides;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Emby stream route receives client identity without selecting a server-local Path',
    () async {
      const target = 'https://resolver.invalid/play?sign=a%2fb&x=1&x=2';
      final data = playbackData(
        url:
            '/proxy/emby/Videos/movie/stream.mkv?Static=true&api_key=SYNTHETIC_TOKEN',
      );
      (data['MediaSources'] as List).first.addAll({
        'Path': target,
        'Protocol': 'Http',
        'SupportsDirectPlay': true,
      });
      final api = EmbyClient(
        client: MockClient((_) async => response(jsonEncode(data), 200)),
      )..session = syntheticSession();
      final route = await api.playback(MediaItem({'Id': 'movie'}));
      expect(Uri.parse(route.url).origin, api.session!.base.origin);
      expect(route.sameOriginHeaders['X-Emby-Token'], api.session!.token);
      expect(
        route.sameOriginHeaders['X-Emby-Authorization'],
        contains('Client="Yingyu"'),
      );
      expect(
        Uri.parse(route.url).queryParameters.containsKey('X-Emby-Token'),
        false,
      );
      expect(route.playMethod, 'DirectStream');
      expect(
        route.headers.keys.map((e) => e.toLowerCase()),
        isNot(anyElement(startsWith('x-emby-'))),
      );
      api.close();
    },
  );
  test(
    'explicit rewritten external or custom routes remain authoritative',
    () async {
      for (final direct in [
        'https://cdn.invalid/ready?sign=EXACT%2f',
        '/custom/resolve?sig=EXACT%2f',
        '/proxy/emby/Videos/movie/stream.mkv?sign=EXACT%2f',
      ]) {
        final data = playbackData(url: direct);
        (data['MediaSources'] as List).first.addAll({
          'Path': 'https://resolver.invalid/old',
          'Protocol': 'Http',
          'SupportsDirectPlay': true,
        });
        final api = EmbyClient(
          client: MockClient((_) async => response(jsonEncode(data), 200)),
        )..session = syntheticSession();
        expect(
          (await api.playback(MediaItem({'Id': 'movie'}))).url,
          resolveMediaAddress(api.session!.base, direct),
        );
        api.close();
      }
    },
  );
  test(
    'server-supplied alternative credentials and signed routes are not overridden',
    () {
      final account = syntheticSession();
      for (final path in [
        '/proxy/emby/Videos/movie/stream?api_key=SERVER_TOKEN',
        '/proxy/emby/Videos/movie/stream?api_key=SYNTHETIC_TOKEN&X-Emby-Token=OTHER',
        '/proxy/emby/Videos/movie/stream?sign=%ff%00',
      ]) {
        expect(
          canUseAccountHeaders(
            Uri.parse('${account.base.origin}$path'),
            account,
          ),
          false,
        );
      }
    },
  );
  test(
    'explicitly disallowed DirectPlay does not select the remote Path',
    () async {
      final data = playbackData(
        url: '/proxy/emby/Videos/movie/stream?Static=true',
      );
      (data['MediaSources'] as List).first.addAll({
        'Path': 'https://resolver.invalid/file',
        'Protocol': 'Http',
        'SupportsDirectPlay': false,
      });
      final api = EmbyClient(
        client: MockClient((_) async => response(jsonEncode(data), 200)),
      )..session = syntheticSession();
      expect(
        (await api.playback(MediaItem({'Id': 'movie'}))).url,
        startsWith(
          'http://127.0.0.1:9/proxy/emby/Videos/movie/stream?Static=true&',
        ),
      );
      api.close();
    },
  );
  test(
    'ordinary Emby Tag metadata does not suppress missing media credentials',
    () {
      const address =
          'https://server.invalid/emby/Videos/movie/stream.mkv?Static=true&Tag=opaque%2ftag&MediaSourceId=selected';
      final result = completeEmbyStreamAddress(
        address,
        Uri.parse('https://server.invalid/emby'),
        {
          'Static': 'true',
          'api_key': 'SYNTHETIC',
          'DeviceId': 'device',
          'MediaSourceId': 'other',
          'PlaySessionId': 'session',
        },
      );
      expect(result, startsWith('$address&'));
      expect(Uri.parse(result).queryParameters['api_key'], 'SYNTHETIC');
      expect(Uri.parse(result).queryParameters['MediaSourceId'], 'selected');
    },
  );
  test(
    'unsigned Emby route keeps its token and explicitly requests the original file',
    () {
      final base = Uri.parse('https://server.invalid/emby');
      const address =
          'https://server.invalid/emby/Videos/movie/stream.mkv?api_key=SERVER_TOKEN';
      final result = completeEmbyStreamAddress(address, base, {
        'api_key': 'ACCOUNT_TOKEN',
        'Static': 'true',
        'MediaSourceId': 'source',
        'PlaySessionId': 'session',
        'DeviceId': 'device',
      });
      expect(result, startsWith('$address&'));
      expect(Uri.parse(result).queryParametersAll['api_key'], ['SERVER_TOKEN']);
      expect(Uri.parse(result).queryParameters['Static'], 'true');
      expect(result, isNot(contains('ACCOUNT_TOKEN')));
    },
  );
  test('opaque signed values are not decoded as UTF8 or rebuilt', () {
    const address =
        'https://server.invalid/emby/Videos/movie/stream.mkv?sign=%ff%00&x=1&x=2';
    expect(
      completeEmbyStreamAddress(
        address,
        Uri.parse('https://server.invalid/emby'),
        {'api_key': 'PRIVATE', 'Static': 'true'},
      ),
      address,
    );
    expect(Media(address, httpHeaders: const {}).uri, address);
  });
  test(
    'signed same-origin stream retains path, signature and repeated query',
    () async {
      const address =
          'http://127.0.0.1:9/proxy/emby/Videos/movie/stream.mkv'
          '?Static=true&api_key=SYNTHETIC&sign=a%2fb%2Bc&x=1&x=2';
      final api = EmbyClient(
        client: MockClient(
          (_) async => response(jsonEncode(playbackData(url: address)), 200),
        ),
      )..session = syntheticSession();
      try {
        final route = await api.playback(MediaItem({'Id': 'movie'}));
        expect(route.url, address);
      } finally {
        api.close();
      }
    },
  );
  test('empty DirectStreamUrl does not hide an HTTP STRM target', () async {
    const address =
        'https://media.invalid/play115?pickcode=SYNTHETIC&sign=a%2Fb';
    final data = playbackData(url: '');
    (data['MediaSources'] as List).first.addAll({
      'Protocol': 'Http',
      'Path': address,
    });
    final api = EmbyClient(
      client: MockClient((_) async => response(jsonEncode(data), 200)),
    )..session = syntheticSession();
    try {
      expect((await api.playback(MediaItem({'Id': 'movie'}))).url, address);
    } finally {
      api.close();
    }
  });
  test(
    'API and media use the same explicit default User-Agent without account headers',
    () async {
      String? apiAgent;
      final api = EmbyClient(
        client: MockClient((request) async {
          apiAgent = request.headers['User-Agent'];
          return response(jsonEncode(playbackData()), 200);
        }),
      )..session = syntheticSession();
      try {
        final route = await api.playback(MediaItem({'Id': 'movie'}));
        expect(apiAgent, isNotNull);
        expect(apiAgent, isNotEmpty);
        expect(route.headers['User-Agent'], apiAgent);
        expect(
          route.headers.keys.map((e) => e.toLowerCase()),
          isNot(anyElement(startsWith('x-emby-'))),
        );
      } finally {
        api.close();
      }
    },
  );
  test(
    'media-kit network URI handoff preserves signature spelling (no native loading)',
    () {
      const address =
          'https://media.invalid/a.mkv?sign=a%2fb%2Bc&literal=%41&x=1&x=2';
      expect(Media(address, httpHeaders: const {}).uri, address);
    },
  );
  test('relative and scheme-relative signed routes retain exact escapes', () {
    final base = Uri.parse('https://server.invalid/proxy/emby');
    const suffix = '?sign=a%2fb%2Bc&literal=%41&x=1&x=2';
    expect(
      resolveMediaAddress(base, 'Videos/movie/original.mkv$suffix'),
      'https://server.invalid/proxy/emby/Videos/movie/original.mkv$suffix',
    );
    expect(
      resolveMediaAddress(base, '//cdn.invalid/a%2fb$suffix'),
      'https://cdn.invalid/a%2fb$suffix',
    );
    expect(
      resolveMediaAddress(base, '/custom/a$suffix'),
      'https://server.invalid/custom/a$suffix',
    );
    expect(
      () => resolveMediaAddress(base, 'https://cdn.invalid/a\nfile:///secret'),
      throwsA(isA<AppFailure>()),
    );
  });
  test(
    'unsigned original route gets missing identity without losing its path',
    () {
      final base = Uri.parse('https://server.invalid/proxy/emby');
      const original =
          'https://server.invalid/proxy/emby/Videos/movie/original.mkv?Static=true&MediaSourceId=chosen';
      final result = completeEmbyStreamAddress(original, base, {
        'api_key': 'SYNTHETIC',
        'Static': 'true',
        'MediaSourceId': 'other',
        'DeviceId': 'device',
        'PlaySessionId': 'session',
      });
      expect(result, startsWith('$original&'));
      expect(Uri.parse(result).queryParametersAll['MediaSourceId'], ['chosen']);
      expect(Uri.parse(result).queryParameters['api_key'], 'SYNTHETIC');
      expect(
        () => completeEmbyStreamAddress(
          original.replaceFirst('Static=true', 'Static=false'),
          base,
          {},
        ),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test(
    'required User-Agent wins case-insensitively and retains media headers',
    () async {
      final api = EmbyClient(
        client: MockClient(
          (_) async => response(
            jsonEncode(
              playbackData(
                url: 'https://cdn.invalid/a?sig=synthetic',
                headers: {
                  'user-agent': 'ResolverSpecific/1',
                  'Referer': 'https://source.invalid/',
                  'Cookie': 'media-only=synthetic',
                  'x-emby-authorization': 'PRIVATE',
                  'X-Emby-Token': 'PRIVATE',
                },
              ),
            ),
            200,
          ),
        ),
      )..session = syntheticSession();
      try {
        final headers = (await api.playback(
          MediaItem({'Id': 'movie'}),
        )).headers;
        expect(headers, {
          'user-agent': 'ResolverSpecific/1',
          'Referer': 'https://source.invalid/',
          'Cookie': 'media-only=synthetic',
        });
      } finally {
        api.close();
      }
    },
  );
  test(
    'signed Media cache follows exact URL and clears previous same-URL headers',
    () {
      const first = 'https://cdn.invalid/video?sign=a%2fb';
      const second = 'https://cdn.invalid/video?sign=a%2Fb';
      final a = Media(first, httpHeaders: const {'User-Agent': 'First'});
      final b = Media(second, httpHeaders: const {'User-Agent': 'Second'});
      expect(Media(a.uri).httpHeaders, {'User-Agent': 'First'});
      expect(Media(b.uri).httpHeaders, {'User-Agent': 'Second'});
      final cleared = Media(first, httpHeaders: const {});
      expect(Media(cleared.uri).httpHeaders, isEmpty);
    },
  );
  test(
    'loopback signed Emby route → two redirects → single-use bytes, matching UA (no MPV)',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cloud = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = 'http://127.0.0.1:${origin.port}';
      var mediaRequests = 0, downloads = 0;
      final observations = <String>[];
      final originSub = origin.listen((request) async {
        if (request.uri.path.endsWith('PlaybackInfo')) {
          expect(request.headers.value('X-Emby-Token'), 'SYNTHETIC_TOKEN');
          expect(request.headers.value('User-Agent'), playbackUserAgent);
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode(
              playbackData(
                url:
                    '$base/proxy/emby/Videos/movie/stream.mkv?api_key=SYNTHETIC&Static=true&sig=a%2Fb%2Bc&x=1&x=2',
              ),
            ),
          );
        } else if (request.uri.path == '/proxy/emby/Videos/movie/stream.mkv') {
          mediaRequests++;
          observations.add(request.headers.value('User-Agent') ?? 'missing');
          expect(request.uri.queryParametersAll['x'], ['1', '2']);
          expect(request.uri.queryParameters['sig'], 'a/b+c');
          expect(request.headers.value('X-Emby-Token'), isNull);
          expect(request.headers.value('X-Emby-Authorization'), isNull);
          request.response.statusCode = 302;
          request.response.headers.set('location', '$base/resolve115');
        } else if (request.uri.path == '/resolve115') {
          observations.add(request.headers.value('User-Agent') ?? 'missing');
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${cloud.port}/once?sign=synthetic',
          );
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final cloudSub = cloud.listen((request) async {
        downloads++;
        observations.add(request.headers.value('User-Agent') ?? 'missing');
        expect(request.headers.value('X-Emby-Token'), isNull);
        expect(request.headers.value('X-Emby-Authorization'), isNull);
        expect(request.uri.queryParameters.containsKey('api_key'), false);
        expect(request.headers.value('Range'), 'bytes=0-3');
        request.response.statusCode = downloads == 1 ? 206 : 403;
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      final api = EmbyClient()..session = syntheticSession('$base/proxy/emby');
      final transfer = HttpClient();
      try {
        final route = await api.playback(MediaItem({'Id': 'movie'}));
        expect(mediaRequests, 0);
        expect(downloads, 0);
        // Model the explicit native user-agent option as well as Media headers.
        // Dart's default redirect handler otherwise restores its own default UA.
        transfer.userAgent = route.headers['User-Agent'];
        final request = await transfer.getUrl(Uri.parse(route.url));
        route.headers.forEach(request.headers.set);
        request.headers.set('Range', 'bytes=0-3');
        final reply = await request.close();
        expect(reply.statusCode, 206);
        expect(await reply.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
          4,
        ]);
        expect(mediaRequests, 1);
        expect(downloads, 1);
        expect(observations, [
          playbackUserAgent,
          playbackUserAgent,
          playbackUserAgent,
        ]);
      } finally {
        api.close();
        transfer.close(force: true);
        await originSub.cancel();
        await cloudSub.cancel();
        await origin.close(force: true);
        await cloud.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
