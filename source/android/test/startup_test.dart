import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'core_test.dart'
    show syntheticSession, response, playbackData, LoopbackHttpOverrides;
import 'playback_test.dart' show FakeBackend;

Json sourceFor(String extension) => {
  'Id': 'source-1',
  'Type': 'Default',
  'Protocol': 'File',
  'Path': '/synthetic/library/movie.$extension',
  'Container': extension,
  'SupportsDirectStream': true,
  'RequiresOpening': false,
  'RequiredHttpHeaders': <String, String>{},
  'MediaStreams': <Json>[],
};
MediaItem detailFor(Json source) => MediaItem({
  'Id': 'movie',
  'Name': '合成测试影片',
  'Type': 'Movie',
  'MediaSources': [source],
  'RunTimeTicks': 54000000000,
  'UserData': {'PlaybackPositionTicks': 12340000000},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final extension in ['mkv', 'mp4', 'iso', 'bdmv']) {
    test(
      'complete fresh $extension uses the original without a second metadata request',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((_) async {
            calls++;
            return response(jsonEncode(playbackData()), 200);
          }),
        )..session = syntheticSession();
        final detail = detailFor(sourceFor(extension));
        final first = await api.preparePlayback(
          detail,
          start: const Duration(seconds: 1234),
        );
        final second = await api.preparePlayback(detail);
        expect(calls, 0);
        final target = Uri.parse(first.url);
        expect(target.origin, api.session!.base.origin);
        expect(
          target.queryParameters['Static'] ?? target.queryParameters['static'],
          'true',
        );
        expect(target.queryParameters['MediaSourceId'], 'source-1');
        expect(target.queryParameters['PlaySessionId'], first.sessionId);
        expect(first.sessionId, isNot(second.sessionId));
        expect(
          first.headers.keys.map((x) => x.toLowerCase()),
          isNot(contains('x-emby-token')),
        );
        expect(
          first.sameOriginHeaders['X-Emby-Authorization'],
          contains('UserId='),
        );
        expect(
          first.discKind,
          extension == 'iso'
              ? DiscKind.iso
              : extension == 'bdmv'
              ? DiscKind.blurayFolder
              : DiscKind.none,
        );
        api.close();
      },
    );
  }
  for (final change in <Json>[
    {'Protocol': 'Rtsp', 'Path': 'rtsp://synthetic.invalid/live'},
    {'DirectStreamUrl': '/emby/Videos/movie/stream?Static=false'},
    {'Type': 'LiveStream'},
    {'RequiresOpening': true},
    {'RequiresClosing': true},
    {'IsInfiniteStream': true},
    {'RequiredHttpHeaders': null},
    {'SupportsDirectStream': false},
    {
      'MediaStreams': [
        {'Type': 'Audio', 'Index': 0},
      ],
    },
  ]) {
    test(
      'incomplete or dynamic source keeps exactly one negotiation: ${change.keys.join()}',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            calls++;
            expect(request.url.path.endsWith('/PlaybackInfo'), true);
            expect(jsonDecode(request.body)['StartTimeTicks'], 12340000000);
            expect(jsonDecode(request.body)['EnableTranscoding'], false);
            return response(
              jsonEncode(
                playbackData(
                  url: 'https://synthetic.invalid/movie?sig=%2f&k=1&k=2',
                ),
              ),
              200,
            );
          }),
        )..session = syntheticSession();
        final result = await api.preparePlayback(
          detailFor({...sourceFor('mkv'), ...change}),
          start: const Duration(seconds: 1234),
        );
        expect(calls, 1);
        expect(result.url, 'https://synthetic.invalid/movie?sig=%2f&k=1&k=2');
        expect(result.sameOriginHeaders, isEmpty);
        api.close();
      },
    );
  }
  test(
    'track defaults, required media headers and explicit source are preserved',
    () async {
      final api = EmbyClient(
        client: MockClient(
          (_) async => throw StateError('Unexpected negotiation'),
        ),
      )..session = syntheticSession();
      final source = {
        ...sourceFor('mkv'),
        'DefaultAudioStreamIndex': 2,
        'DefaultSubtitleStreamIndex': -1,
        'RequiredHttpHeaders': {
          'Referer': 'https://synthetic.invalid/',
          'X-Emby-Token': 'DO_NOT_FORWARD',
        },
        'MediaStreams': [
          {'Type': 'Audio', 'Index': 2, 'Codec': 'truehd', 'Channels': 8},
        ],
      };
      final route = await api.preparePlayback(
        MediaItem({
          ...detailFor(source).data,
          'MediaSources': [
            {...sourceFor('mp4'), 'Id': 'other'},
            source,
          ],
        }),
        sourceId: 'source-1',
      );
      expect(route.sourceId, 'source-1');
      expect(route.defaultAudioIndex, 2);
      expect(route.defaultSubtitleIndex, -1);
      expect(route.streams.single['Codec'], 'truehd');
      expect(route.headers['Referer'], 'https://synthetic.invalid/');
      expect(route.headers['X-Emby-Token'], isNull);
      api.close();
    },
  );
  for (final extension in ['mkv', 'iso', 'strm']) {
    test(
      'remote $extension reuses explicit entry instead of raw source Path',
      () async {
        final api = EmbyClient(
          client: MockClient(
            (_) async => response(
              jsonEncode({
                'PlaySessionId': 'fresh-session',
                'MediaSources': [
                  {
                    ...sourceFor(extension),
                    'DirectStreamUrl':
                        '/emby/Videos/movie/stream?Static=true&MediaSourceId=source-1',
                  },
                ],
              }),
              200,
            ),
          ),
        )..session = syntheticSession();
        final route = await api.preparePlayback(
          detailFor({
            ...sourceFor(extension),
            'Protocol': 'Http',
            'Path': 'https://synthetic.invalid/movie.$extension?expired=old%2f',
            'DirectStreamUrl':
                '/emby/Videos/movie/stream?Static=true&MediaSourceId=source-1',
          }),
        );
        expect(Uri.parse(route.url).origin, api.session!.base.origin);
        expect(route.url, isNot(contains('expired')));
        expect(route.sameOriginHeaders, isNotEmpty);
        expect(
          route.discKind,
          extension == 'iso' ? DiscKind.iso : DiscKind.none,
        );
        api.close();
      },
    );
  }
  test(
    'session reaches backend without waiting for redundant PlaybackInfo and still uses fresh progress',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final backend = FakeBackend();
      var infoCalls = 0, details = 0;
      final api = EmbyClient(
        client: MockClient((req) async {
          if (req.url.path.endsWith('/PlaybackInfo')) {
            infoCalls++;
            await Future<void>.delayed(const Duration(seconds: 1));
            return response(jsonEncode(playbackData()), 200);
          }
          if (req.url.path.contains('/Sessions/Playing')) {
            return response('', 204);
          }
          details++;
          return response(jsonEncode(detailFor(sourceFor('mkv')).data), 200);
        }),
      )..session = syntheticSession();
      final player = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({
          'Id': 'movie',
          'UserData': {'PlaybackPositionTicks': 0},
        }),
        backend: backend,
      );
      final opening = player.open();
      await backend.opened.future.timeout(const Duration(milliseconds: 400));
      expect(details, 1);
      expect(infoCalls, 0);
      expect(backend.initial, const Duration(seconds: 1234));
      expect(player.ready, false);
      expect(backend.plays, 0);
      backend.gate.complete();
      await opening;
      expect(player.ready, true);
      await player.close();
      player.dispose();
      api.close();
      store.dispose();
    },
  );
  test('account switch during fresh detail never opens any source', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(await SharedPreferences.getInstance());
    final backend = FakeBackend();
    final gate = Completer<void>();
    final api = EmbyClient(
      client: MockClient((_) async {
        await gate.future;
        return response(jsonEncode(detailFor(sourceFor('mkv')).data), 200);
      }),
    )..session = syntheticSession();
    final player = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    final opening = player.open();
    api.session = syntheticSession('http://127.0.0.1:10/emby');
    gate.complete();
    await opening;
    expect(backend.opened.isCompleted, false);
    expect(player.error, contains('账户已切换'));
    await player.close();
    player.dispose();
    api.close();
    store.dispose();
  });
  test(
    'expired account is reported without opening a source or uncaught error',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final backend = FakeBackend();
      final api = EmbyClient(
        client: MockClient(
          (_) async => throw StateError('No account must not make requests'),
        ),
      );
      final player = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      await player.open();
      expect(player.error, contains('登录已过期'));
      expect(backend.opened.isCompleted, false);
      await player.close();
      player.dispose();
      api.close();
      store.dispose();
    },
  );
  test(
    'complete remote STRM skips negotiation then resolves one authenticated entry',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var details = 0, negotiations = 0, entries = 0, mediaRanges = 0;
      final api = EmbyClient()
        ..session = syntheticSession('http://127.0.0.1:${server.port}/emby');
      final target =
          'http://127.0.0.1:${media.port}/original.mkv?sig=%2f&k=1&k=2';
      server.listen((req) async {
        expect(req.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
        expect(req.headers.value('x-emby-authorization'), contains('UserId='));
        if (req.uri.path.contains('/Users/')) {
          details++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode(
              detailFor({
                ...sourceFor('strm'),
                'Protocol': 'Http',
                'Path': 'https://synthetic.invalid/stale.mkv?expired=yes',
              }).data,
            ),
          );
        } else if (req.uri.path.endsWith('/PlaybackInfo')) {
          negotiations++;
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'PlaySessionId': 'fresh-session',
              'MediaSources': [sourceFor('strm')],
            }),
          );
        } else {
          entries++;
          expect(req.uri.queryParameters['Static'], 'true');
          expect(req.uri.queryParameters['MediaSourceId'], 'source-1');
          expect(req.uri.queryParameters['PlaySessionId'], isNotEmpty);
          req.response.statusCode = 302;
          req.response.headers.set('Location', target);
        }
        await req.response.close();
      });
      media.listen((req) async {
        mediaRanges++;
        expect(req.headers.value('x-emby-token'), isNull);
        expect(req.headers.value('x-emby-authorization'), isNull);
        // HttpServer's Uri parser uppercases percent escapes. Exact opaque URL
        // preservation is covered separately before transport/Uri parsing.
        expect(req.uri.query, 'sig=%2F&k=1&k=2');
        req.response.statusCode = 206;
        req.response.contentLength = 8;
        req.response.add(List.filled(8, 7));
        await req.response.close();
      });
      final route = await api.preparePlayback(await api.detail('movie'));
      final transport = EmbyOriginTransport(route);
      final client = HttpClient();
      try {
        final address = Uri.parse(await transport.start());
        for (var i = 0; i < 2; i++) {
          final request = await client.getUrl(address);
          request.headers.set('Range', 'bytes=${i * 8}-${i * 8 + 7}');
          final result = await request.close();
          expect(result.statusCode, 206);
          expect(await result.fold<int>(0, (n, bytes) => n + bytes.length), 8);
        }
        expect(details, 1);
        expect(negotiations, 0);
        expect(entries, 1);
        expect(mediaRanges, 2);
      } finally {
        client.close(force: true);
        await transport.close();
        api.close();
        await server.close(force: true);
        await media.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
