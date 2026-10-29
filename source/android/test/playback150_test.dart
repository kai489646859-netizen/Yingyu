import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:yingyu/playback/controls.dart';
import 'host/playback150/old_controls.dart' as old_controls;
import 'host/playback150/old_home_feed.dart' as old_home;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'core_test.dart' show response, syntheticSession;
import 'watch_resume131_test.dart' show ep;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final released in [true, false]) {
    test(
      'server Resume cache takes precedence over legacy local episode history, delivered149=$released',
      () async {
        final stale = ep(14, seconds: 500, date: '2026-10-20T00:00:00Z');
        final recent = MediaItem({
          ...ep(17, seconds: 310, date: '2026-10-20T00:02:00Z').data,
          'UserData': {
            ...object(
              ep(
                17,
                seconds: 310,
                date: '2026-10-20T00:02:00Z',
              ).data['UserData'],
            ),
            'Played': false,
          },
        });
        var remote = stale;
        final prefs = await SharedPreferences.getInstance();
        final store = AppStore(prefs);
        final api = EmbyClient(
          client: MockClient(
            (_) async => response(
              jsonEncode({
                'Items': [remote.data],
              }),
              200,
            ),
          ),
        )..session = syntheticSession();
        dynamic open({BrowseRepository? browse}) => released
            ? old_home.HomeFeed(api, store, browse: browse)
            : HomeFeed(api, store, browse: browse);
        dynamic feed = open();
        await prefs.setString(
          feed.cacheKey,
          jsonEncode({
            'items': [
              {'item': recent.data, 'observedAt': '2026-10-20T00:03:00Z'},
            ],
          }),
        );
        feed.dispose();
        final browse = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        await browse.cache.put(
          browse.key('resume:0:18'),
          ItemPage([stale], 1),
          DateTime.now(),
        );
        feed = open(browse: browse);
        try {
          expect(store.localProgress(api.session!, recent.id), isNull);
          expect(feed.resume.single.id, 'e14');
          expect(feed.resume.single.resume, const Duration(seconds: 500));
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'e14');
          remote = ep(14, seconds: 100, date: '2026-10-20T01:00:00Z');
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'e14');
          expect(feed.resume.single.resume, const Duration(seconds: 100));
        } finally {
          feed.dispose();
          browse.dispose();
          api.close();
          store.dispose();
        }
      },
    );
  }
  test(
    'detail checkpoint stays separate from server Resume across store/API/feed recreation',
    () async {
      final stale = ep(14, seconds: 500, date: '2026-10-25T00:00:00Z');
      final current = ep(16, seconds: 22, date: '2026-10-25T00:02:00Z');
      var remote = stale;
      final methods = <String>[];
      final prefs = await SharedPreferences.getInstance();
      var store = AppStore(prefs);
      EmbyClient apiFor() => EmbyClient(
        client: MockClient((r) async {
          methods.add(r.method);
          return response(
            jsonEncode({
              'Items': [
                r.url.path.endsWith('/Resume') ? remote.data : current.data,
              ],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      var api = apiFor();
      var feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      expect((await feed.lastWatchedEpisode('series'))!.id, 'e16');
      expect(feed.resume.single.id, 'e14');
      feed.dispose();
      api.close();
      store.dispose();
      store = AppStore(prefs);
      api = apiFor();
      feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true);
        expect(
          feed.resume.single.id,
          'e14',
          reason:
              'The server Resume checkpoint remains authoritative after an overwrite restart.',
        );
        expect(feed.resume.single.resume, const Duration(seconds: 500));
        expect((await feed.lastWatchedEpisode('series'))!.id, 'e16');
        remote = ep(14, seconds: 123, date: '2026-10-25T00:03:00Z');
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, const Duration(seconds: 123));
        expect(methods, everyElement('GET'));
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  for (final corrupt in [false, true]) {
    test(
      'optional display history is account scoped and tolerates corruption=$corrupt',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = AppStore(prefs);
        final api = EmbyClient(
          client: MockClient((_) async => response('{"Items": []}', 200)),
        )..session = syntheticSession();
        final feed = HomeFeed(api, store);
        final key = feed.verifiedHistoryKey;
        feed.dispose();
        await prefs.setString(
          corrupt ? key : '${key}_different_account',
          corrupt
              ? '{broken'
              : jsonEncode({
                  'version': 1,
                  'items': [
                    {'item': ep(16, seconds: 22).data, 'baseline': '[]'},
                  ],
                }),
        );
        final restarted = HomeFeed(api, store);
        try {
          expect(restarted.recentEpisode('series'), isNull);
          await restarted.refreshResume(force: true);
          expect(restarted.resume, isEmpty);
        } finally {
          restarted.dispose();
          api.close();
          store.dispose();
        }
      },
    );
  }
  for (final phone in [true, false]) {
    testWidgets(
      'timeline moves down on phone only, full released/current controls phone=$phone',
      (tester) async {
        final size = phone ? const Size(1056, 480) : const Size(1280, 800);
        setDisplay(tester, size, dpr: phone ? 3 : 1);
        final capture = GlobalKey();
        var sought = 0;
        var back = 0;
        var forward = 0;
        Widget chrome(bool released) {
          final widget = released
              ? old_controls.PlayerChrome(
                  title: '合成剧 · 第 1 季 · 第 17 集',
                  visible: true,
                  ready: true,
                  playing: true,
                  position: const Duration(minutes: 4, seconds: 32),
                  duration: const Duration(minutes: 13),
                  onBack: () {},
                  onToggle: () {},
                  onSeekBack: () => back++,
                  onSeekForward: () => forward++,
                  onMenu: () {},
                  onScrubStart: () {},
                  onScrub: (_) {},
                  onScrubEnd: (_) => sought++,
                  episode: true,
                  onPrevious: () {},
                  onNext: () {},
                  onRate: () {},
                  onAudio: () {},
                  onSubtitles: () {},
                  onEpisodes: () {},
                )
              : PlayerChrome(
                  title: '合成剧 · 第 1 季 · 第 17 集',
                  visible: true,
                  ready: true,
                  playing: true,
                  position: const Duration(minutes: 4, seconds: 32),
                  duration: const Duration(minutes: 13),
                  onBack: () {},
                  onToggle: () {},
                  onSeekBack: () => back++,
                  onSeekForward: () => forward++,
                  onMenu: () {},
                  onScrubStart: () {},
                  onScrub: (_) {},
                  onScrubEnd: (_) => sought++,
                  episode: true,
                  onPrevious: () {},
                  onNext: () {},
                  onRate: () {},
                  onAudio: () {},
                  onSubtitles: () {},
                  onEpisodes: () {},
                );
          return MaterialApp(
            home: RepaintBoundary(
              key: capture,
              child: Material(
                color: Colors.black,
                child: Stack(children: [widget]),
              ),
            ),
          );
        }

        await tester.pumpWidget(chrome(true));
        await tester.pumpAndSettle();
        final oldTop = tester
            .getCenter(find.byKey(const Key('playback-timeline')))
            .dy;
        await tester.pumpWidget(chrome(false));
        await tester.pumpAndSettle();
        final newTop = tester
            .getCenter(find.byKey(const Key('playback-timeline')))
            .dy;
        expect(newTop - oldTop, phone ? 8 : 0);
        await tester.tap(find.byKey(const Key('playback-timeline')));
        await tester.pumpAndSettle();
        expect(sought, 1);
        await tester.tap(find.byTooltip('快退 10 秒'));
        await tester.tap(find.byTooltip('快进 10 秒'));
        await tester.pumpAndSettle();
        expect(back, 1);
        expect(forward, 1);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final render =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/playback150/previews/controls-${phone ? 'phone' : 'tablet'}.png',
          )..parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
