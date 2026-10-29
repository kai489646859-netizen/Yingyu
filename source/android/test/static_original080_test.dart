import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'core_test.dart'
    show response, syntheticSession, playbackData, LoopbackHttpOverrides;
import 'startup_test.dart' show sourceFor, detailFor;

Json completeStaticSource([Json changes = const {}]) => {
  ...sourceFor('mkv'),
  'Protocol': 'Http',
  'IsRemote': true,
  'Path': 'https://server-side.invalid/source.mkv?opaque=source-only',
  'DefaultAudioStreamIndex': 2,
  'DefaultSubtitleStreamIndex': -1,
  'RequiredHttpHeaders': {
    'Referer': 'https://required.invalid/',
    'X-Media-Required': 'synthetic-required-value',
    'X-Emby-Token': 'DO_NOT_FORWARD',
  },
  'MediaStreams': [
    {'Type': 'Video', 'Index': 0, 'Codec': 'hevc', 'DoviProfile': 8},
    {'Type': 'Audio', 'Index': 2, 'Codec': 'truehd'},
  ],
  ...changes,
};

// Remote sources without a client URL now negotiate (opening137_test.dart).
// Keep the independent static/auth/range and local-fast-path coverage here.
Json completeLocalStaticSource([Json changes = const {}]) =>
    completeStaticSource({
      'Protocol': 'File',
      'IsRemote': false,
      'Path': '/synthetic/library/source.mkv',
      ...changes,
    });

Future<void> exerciseStaticLoopback(String extension) async {
  await HttpOverrides.runWithHttpOverrides(() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final base = 'http://127.0.0.1:${server.port}/proxy/emby';
    final signed =
        'http://127.0.0.1:${media.port}/signed/asset.$extension'
        '?signature=a%2fb%2Bc&part=1&part=2';
    final account = syntheticSession(base);
    final bytes = List.generate(8192, (index) => index % 251);
    final agent = 'Synthetic-Original-080/$extension';
    final source = completeStaticSource({
      'Container': extension,
      'Path': '$base/server-source.$extension?opaque=never-open',
      'DirectStreamUrl': '$base/Videos/movie/stream.$extension',
      'RequiredHttpHeaders': {
        'User-Agent': agent,
        'Referer': 'https://required.invalid/',
        'X-Media-Required': 'synthetic-required-value',
        'X-Emby-Token': 'DO_NOT_FORWARD',
      },
    });
    var details = 0, negotiations = 0, entries = 0, targets = 0;
    var forbiddenPaths = 0, nativeCalls = 0;
    var denyTarget = false;
    PlaybackRoute? route;
    server.listen((request) async {
      if (request.uri.path == '/proxy/emby/Users/synthetic-user/Items/movie') {
        details++;
        expect(request.headers.value('x-emby-token'), account.token);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(detailFor(source).data));
      } else if (request.uri.path == '/proxy/emby/Items/movie/PlaybackInfo') {
        negotiations++;
        // A mistaken negotiation must time out rather than being rescued by
        // a synthetic response. This endpoint intentionally never replies.
        return;
      } else if (request.uri.path ==
          '/proxy/emby/Videos/movie/stream.$extension') {
        entries++;
        expect(request.method, 'GET');
        expect(request.uri.queryParameters['Static'], 'true');
        expect(request.uri.queryParameters['MediaSourceId'], 'source-1');
        expect(request.uri.queryParameters['PlaySessionId'], route!.sessionId);
        expect(request.uri.queryParameters['DeviceId'], account.deviceId);
        expect(request.uri.queryParameters['api_key'], account.token);
        expect(request.headers.value('x-emby-token'), account.token);
        expect(
          request.headers.value('x-emby-authorization'),
          contains('UserId='),
        );
        expect(request.headers.value('user-agent'), agent);
        expect(
          request.headers.value('x-media-required'),
          'synthetic-required-value',
        );
        expect(request.headers.value('range'), 'bytes=0-4095');
        request.response.statusCode = 302;
        request.response.headers.set('Location', signed);
        request.response.contentLength = 0;
      } else {
        forbiddenPaths++;
        request.response.statusCode = 503;
      }
      await request.response.close();
    });
    media.listen((request) async {
      targets++;
      expect(request.uri.path, '/signed/asset.$extension');
      expect(request.uri.query, Uri.parse(signed).query);
      expect(request.headers.value('x-emby-token'), isNull);
      expect(request.headers.value('x-emby-authorization'), isNull);
      expect(request.uri.queryParameters.containsKey('api_key'), false);
      expect(request.headers.value('user-agent'), agent);
      expect(request.headers.value('referer'), 'https://required.invalid/');
      expect(
        request.headers.value('x-media-required'),
        'synthetic-required-value',
      );
      if (denyTarget) {
        request.response.statusCode = 403;
        request.response.write('synthetic target denied');
      } else {
        final range = RegExp(
          r'^bytes=(\d+)-(\d+)$',
        ).firstMatch(request.headers.value('range') ?? '');
        expect(range, isNotNull);
        final start = int.parse(range![1]!);
        final end = int.parse(range[2]!);
        expect(start, greaterThanOrEqualTo(0));
        expect(end, lessThan(bytes.length));
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/${bytes.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(bytes.sublist(start, end + 1));
      }
      await request.response.close();
    });
    final api = EmbyClient(timeout: const Duration(seconds: 2))
      ..session = account;
    final client = HttpClient()..autoUncompress = false;
    EmbyOriginTransport? origin;
    DiscTransport? disc;
    try {
      final detail = await api.detail('movie');
      final prepared = await api.preparePlayback(detail, sourceId: 'source-1');
      route = prepared;
      expect(details, 1);
      expect(negotiations, 0);
      expect(prepared.sourceId, 'source-1');
      expect(prepared.defaultAudioIndex, 2);
      expect(prepared.defaultSubtitleIndex, -1);
      expect(prepared.streams, source['MediaStreams']);
      expect(prepared.url, isNot(source['Path']));

      if (extension == 'iso') {
        final failures = <String>[];
        disc = DiscTransport(
          prepared,
          kind: DiscKind.iso,
          directInput: true,
          onFailure: failures.add,
          nativeInvoke: (_, _) async {
            nativeCalls++;
            return null;
          },
        );
        final cancelled = DiscReadCancellation()..cancel();
        await expectLater(
          disc.readNativeInput(1, '', 0, 4096, cancelled),
          throwsA(isA<AppFailure>()),
        );
        expect(entries, 0);
        expect(targets, 0);
        expect(failures, isEmpty);
        final first = await disc.readNativeInput(
          1,
          '',
          0,
          4096,
          DiscReadCancellation(),
        );
        final second = await disc.readNativeInput(
          1,
          '',
          1024,
          1024,
          DiscReadCancellation(),
        );
        expect(first!.bytes, bytes.sublist(0, 4096));
        expect(first.start, 0);
        expect(first.total, bytes.length);
        expect(second!.bytes, bytes.sublist(1024, 2048));
        expect(second.start, 1024);
        expect(second.total, bytes.length);
        denyTarget = true;
        final failure = throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('403'),
          ),
        );
        await expectLater(
          disc.readNativeInput(1, '', 2048, 1024, DiscReadCancellation()),
          failure,
        );
        expect(failures, hasLength(1));
        expect(failures.single, contains('403'));
        // A terminal signed-target rejection remains terminal for this entry.
        await expectLater(
          disc.readNativeInput(1, '', 2048, 1024, DiscReadCancellation()),
          failure,
        );
      } else {
        origin = EmbyOriginTransport(prepared);
        final address = await origin.start();
        Future<({int status, List<int> bytes})> readRange(
          int start,
          int end,
        ) async {
          final request = await client.getUrl(Uri.parse(address));
          request.followRedirects = false;
          prepared.headers.forEach(request.headers.set);
          request.headers.set('Range', 'bytes=$start-$end');
          final redirected = await request.close();
          expect(redirected.statusCode, 302);
          final location = redirected.headers.value('location');
          expect(location, signed);
          await redirected.listen((_) {}).cancel();
          // MPV receives this signed Location and ordinary media headers only.
          // The IO client substitutes for its fetch; no decoder is loaded.
          final target = await client.getUrl(Uri.parse(location!));
          target.followRedirects = false;
          prepared.headers.forEach(target.headers.set);
          target.headers.set('Range', 'bytes=$start-$end');
          final response = await target.close();
          return (
            status: response.statusCode,
            bytes: await response.fold<List<int>>(
              [],
              (all, next) => all..addAll(next),
            ),
          );
        }

        final first = await readRange(0, 4095);
        final second = await readRange(1024, 2047);
        expect(first.status, 206);
        expect(first.bytes, bytes.sublist(0, 4096));
        expect(second.status, 206);
        expect(second.bytes, bytes.sublist(1024, 2048));
        denyTarget = true;
        final rejected = await readRange(2048, 3071);
        expect(rejected.status, 403);
        expect(utf8.decode(rejected.bytes), 'synthetic target denied');
      }

      expect(entries, 1);
      expect(targets, 3);
      expect(negotiations, 0);
      expect(forbiddenPaths, 0);
      expect(nativeCalls, 0);
    } finally {
      await origin?.close();
      await disc?.close();
      client.close(force: true);
      api.close();
      await server.close(force: true);
      await media.close(force: true);
    }
  }, LoopbackHttpOverrides());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final extension in ['mkv', 'iso']) {
    test(
      'regression080 static $extension real transport resolves signed 302 once',
      () => exerciseStaticLoopback(extension),
    );
  }

  final staticCases = <String, Json>{
    'local MKV': {},
    'local ISO': {'Container': 'iso', 'Path': '/synthetic/library/source.iso'},
    'STRM container': {
      'Protocol': 'File',
      'Container': 'strm',
      'Path': '/synthetic/library/movie.strm',
    },
    'STRM path with known media container': {
      'Protocol': 'File',
      'Container': 'mkv',
      'Path': '/synthetic/library/movie.STRM',
    },
  };
  for (final entry in staticCases.entries) {
    test(
      'regression080 complete ${entry.key} uses one static entry without PlaybackInfo',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            calls++;
            throw TimeoutException(
              'PlaybackInfo must not block a static source',
            );
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        final source = completeLocalStaticSource(entry.value);
        final detail = MediaItem({
          ...detailFor(source).data,
          'MediaSources': [
            {...sourceFor('mp4'), 'Id': 'other-source'},
            source,
          ],
        });

        final first = await api.preparePlayback(
          detail,
          sourceId: 'source-1',
          start: const Duration(seconds: 1234),
        );
        final second = await api.preparePlayback(detail, sourceId: 'source-1');
        final target = Uri.parse(first.url);

        expect(calls, 0);
        expect(target.origin, api.session!.base.origin);
        expect(
          target.path,
          '/proxy/emby/Videos/movie/stream${source['Container'] == 'strm' ? '' : '.${source['Container']}'}',
        );
        expect(target.queryParameters['Static'], 'true');
        expect(target.queryParameters['MediaSourceId'], 'source-1');
        expect(target.queryParameters['PlaySessionId'], first.sessionId);
        expect(target.queryParameters['DeviceId'], api.session!.deviceId);
        expect(target.queryParameters['api_key'], api.session!.token);
        expect(first.url, isNot(source['Path']));
        expect(target.host, isNot('server-side.invalid'));
        expect(target.queryParameters.containsKey('opaque'), false);
        expect(first.sourceId, 'source-1');
        expect(first.sessionId, isNotEmpty);
        expect(first.sessionId, isNot(second.sessionId));
        expect(first.playMethod, 'DirectStream');
        expect(first.defaultAudioIndex, 2);
        expect(first.defaultSubtitleIndex, -1);
        expect(first.streams, source['MediaStreams']);
        expect(first.headers['Referer'], 'https://required.invalid/');
        expect(first.headers['X-Media-Required'], 'synthetic-required-value');
        expect(first.headers['User-Agent'], isNotEmpty);
        expect(first.headers['X-Emby-Token'], isNull);
        expect(first.sameOriginHeaders['X-Emby-Token'], api.session!.token);
        expect(
          first.sameOriginHeaders['X-Emby-Authorization'],
          contains('UserId='),
        );
        expect(first.serverBase, api.session!.base);
        expect(
          first.discKind,
          entry.value['Container'] == 'iso' ? DiscKind.iso : DiscKind.none,
        );
      },
    );
  }

  for (final direct in [
    'https://media.invalid/original.mkv?sig=a%2fb%2Bc&part=1&part=2',
    '/proxy/emby/custom-route/movie?signature=opaque%2fvalue',
    '/proxy/emby/Videos/movie/stream?Static=true&signature=opaque',
  ]) {
    test(
      'regression080 explicit original entry stays preferred: $direct',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((_) async {
            calls++;
            throw StateError('Explicit original route must not negotiate');
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        final source = completeStaticSource({'DirectStreamUrl': direct});
        final route = await api.preparePlayback(
          detailFor(source),
          sourceId: 'source-1',
        );

        expect(calls, 0);
        expect(route.url, resolveMediaAddress(api.session!.base, direct));
        expect(route.url, isNot(source['Path']));
        expect(route.sourceId, 'source-1');
        expect(route.defaultAudioIndex, 2);
        expect(route.defaultSubtitleIndex, -1);
        expect(route.streams, source['MediaStreams']);
        expect(route.headers['Referer'], 'https://required.invalid/');
        if (Uri.parse(route.url).origin != api.session!.base.origin) {
          expect(route.sameOriginHeaders, isEmpty);
          expect(
            Uri.parse(route.url).queryParameters.containsKey('api_key'),
            false,
          );
        }
      },
    );
  }

  final negotiatedCases = <String, Json>{
    'requires opening': {'RequiresOpening': true},
    'requires closing': {'RequiresClosing': true},
    'infinite stream': {'IsInfiniteStream': true},
    'live source': {'Type': 'LiveStream'},
    'grouping source': {'Type': 'Grouping'},
    'open token': {'OpenToken': 'synthetic-open'},
    'live stream ID': {'LiveStreamId': 'synthetic-live'},
    'missing source identity': {'Id': ''},
    'missing path': {'Path': ''},
    'missing required-header declaration': {'RequiredHttpHeaders': null},
    'missing media streams': {'MediaStreams': null},
    'direct stream disallowed': {'SupportsDirectStream': false},
    'unsupported source protocol': {
      'Protocol': 'Rtsp',
      'Path': 'rtsp://source.invalid/live',
    },
    'explicit non-static route': {
      'DirectStreamUrl': '/proxy/emby/Videos/movie/stream?Static=false',
    },
    'conflicting static parameters': {
      'DirectStreamUrl':
          '/proxy/emby/Videos/movie/stream?Static=true&static=false',
    },
    'previous route session': {
      'DirectStreamUrl':
          '/proxy/emby/Videos/movie/stream?Static=true&PlaySessionId=previous',
    },
    'different route source': {
      'DirectStreamUrl':
          '/proxy/emby/Videos/movie/stream?Static=true&MediaSourceId=other',
    },
    'unsupported explicit route protocol': {
      'DirectStreamUrl': 'file:///private/movie.mkv',
    },
    'invalid explicit address': {'DirectStreamUrl': 'https://'},
  };
  for (final entry in negotiatedCases.entries) {
    test('regression080 ${entry.key} retains one negotiation', () async {
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          calls++;
          expect(request.method, 'POST');
          expect(request.url.path, '/proxy/emby/Items/movie/PlaybackInfo');
          final body = jsonDecode(request.body) as Map;
          expect(body['EnableTranscoding'], false);
          expect(body['StartTimeTicks'], 12340000000);
          return response(jsonEncode(playbackData()), 200);
        }),
      )..session = syntheticSession();
      addTearDown(api.close);

      final route = await api.preparePlayback(
        detailFor(completeLocalStaticSource(entry.value)),
        start: const Duration(seconds: 1234),
      );

      expect(calls, 1);
      expect(route.sourceId, 'source-1');
      expect(route.sessionId, 'synthetic-play');
    });
  }

  for (final missingDefault in [
    'DefaultAudioStreamIndex',
    'DefaultSubtitleStreamIndex',
  ]) {
    test(
      'regression080 known tracks without $missingDefault still negotiate',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            calls++;
            expect(request.url.path, endsWith('/PlaybackInfo'));
            return response(jsonEncode(playbackData()), 200);
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        final source = completeLocalStaticSource()..remove(missingDefault);

        await api.preparePlayback(detailFor(source));

        expect(calls, 1);
      },
    );
  }

  test(
    'regression080 absent selected source never silently uses another source',
    () async {
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          calls++;
          expect(jsonDecode(request.body)['MediaSourceId'], 'missing-source');
          return response(jsonEncode(playbackData()), 200);
        }),
      )..session = syntheticSession();
      addTearDown(api.close);

      await expectLater(
        api.preparePlayback(
          detailFor(completeStaticSource()),
          sourceId: 'missing-source',
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
    },
  );
}
