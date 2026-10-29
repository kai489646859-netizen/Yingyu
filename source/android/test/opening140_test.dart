import 'dart:async';
import 'package:flutter/material.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/controls.dart';
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
                    'SupportsDirectPlay': true,
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
  test('episode ordinal in Name appears only once in playback title', () {
    final item = MediaItem({
      'Type': 'Episode',
      'Name': '第11集',
      'SeriesName': '合成剧集',
      'ParentIndexNumber': 1,
      'IndexNumber': 11,
    });
    expect(playbackTitle(item), '合成剧集 · 第 1 季 · 第 11 集');
  });
  test('real episode name survives an identical leading ordinal', () {
    final item = MediaItem({
      'Type': 'Episode',
      'Name': '第 11 集：宝物之谜',
      'SeriesName': '合成剧集',
      'ParentIndexNumber': 1,
      'IndexNumber': 11,
    });
    expect(playbackTitle(item), '合成剧集 · 第 1 季 · 第 11 集 · 宝物之谜');
  });
  test('different ordinal and non-episode names remain visible', () {
    expect(playbackTitle(MediaItem({'Type': 'Movie', 'Name': '第11集'})), '第11集');
    expect(
      playbackTitle(
        MediaItem({'Type': 'Episode', 'Name': '第12集', 'IndexNumber': 11}),
      ),
      '第 11 集 · 第12集',
    );
  });

  testWidgets('actual loading chrome shows one episode ordinal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final item = MediaItem({
      'Type': 'Episode',
      'Name': '第11集',
      'SeriesName': '合成剧集',
      'ParentIndexNumber': 1,
      'IndexNumber': 11,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              PlayerChrome(
                title: playbackTitle(item),
                visible: true,
                ready: false,
                playing: false,
                episode: true,
                position: Duration.zero,
                duration: Duration.zero,
                onBack: () {},
                onToggle: () {},
                onSeekBack: () {},
                onSeekForward: () {},
                onMenu: () {},
                onScrubStart: () {},
                onScrub: (_) {},
                onScrubEnd: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('合成剧集 · 第 1 季 · 第 11 集'), findsOneWidget);
    expect(find.textContaining('第11集'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
