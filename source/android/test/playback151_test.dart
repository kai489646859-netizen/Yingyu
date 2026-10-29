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
  test(
    'two series keep the server snapshot without global history or per-card queries',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      MediaItem other(MediaItem item) =>
          MediaItem({...item.data, 'Id': 'b${item.id}', 'SeriesId': 'other'});
      final a = ep(14, seconds: 500, date: '2026-10-25T00:00:00Z');
      final b = other(a);
      final fresh = ep(17, seconds: 310, date: '2026-10-25T00:02:00Z');
      var batches = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          final batch = request.url.queryParameters['SortBy'] == 'DatePlayed';
          if (batch) {
            batches++;
            expect(request.url.queryParameters['Limit'], '96');
            expect(
              request.url.queryParameters.containsKey('ParentId'),
              isFalse,
            );
          }
          return response(
            jsonEncode({
              'Items': batch
                  ? [
                      fresh.data,
                      other(fresh).data,
                      {...fresh.data, 'Id': 'unrelated', 'SeriesId': 'absent'},
                    ]
                  : [a.data, b.data],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true, useCache: true);
        expect(feed.resume.map((e) => e.id), ['e14', 'be14']);
        expect(feed.resume.map((e) => e.resume.inSeconds), [500, 500]);
        await feed.refreshResume(force: true, useCache: true);
        expect(batches, 0);
        feed.suspend();
        await feed.refreshResume(force: true);
        expect(
          batches,
          0,
          reason:
              'Browsing reconciliation must not run in the playback suspension scope.',
        );
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  test('cold homepage keeps Resume14 despite history17 and a detail read', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = AppStore(prefs);
    final stale = ep(14, seconds: 500, date: '2026-10-25T00:00:00Z');
    final latest = ep(17, seconds: 310, date: '2026-10-25T00:02:00Z');
    final requests = <String>[];
    final api = EmbyClient(
      client: MockClient((request) async {
        requests.add(
          request.url.path.endsWith('/Resume') ? 'Resume' : 'DatePlayed',
        );
        return response(
          jsonEncode({
            'Items': [
              request.url.path.endsWith('/Resume') ? stale.data : latest.data,
            ],
          }),
          200,
        );
      }),
    )..session = syntheticSession();
    final feed = HomeFeed(api, store);
    try {
      await feed.refreshResume(force: true);
      final before = feed.resume.single;
      expect(
        requests,
        ['Resume'],
        reason:
            'One Resume response, no homepage history substitution or per-card requests.',
      );
      await feed.lastWatchedEpisode('series');
      final after = feed.resume.single;
      final artifact = File('build/playback151/home-before-after.json')
        ..parent.createSync(recursive: true);
      artifact.writeAsStringSync(
        jsonEncode({
          'fixture':
              'Synthetic Resume14, DatePlayed17, no previous verified cache. Real device response not available.',
          'before': {'id': before.id, 'seconds': before.resume.inSeconds},
          'after': {'id': after.id, 'seconds': after.resume.inSeconds},
          'requests': requests,
        }),
      );
      expect(after.id, 'e14');
      expect(after.resume, stale.resume);
      expect(
        before.id,
        'e14',
        reason:
            'The homepage retains the actual Resume episode when details opens.',
      );
    } finally {
      feed.dispose();
      api.close();
      store.dispose();
    }
  });
  for (final freshDate in [false, true]) {
    test(
      'local17 cannot displace server Resume14 without detail, freshDate=$freshDate',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = AppStore(prefs);
        final stale = ep(14, seconds: 500, date: '2026-10-25T00:00:00Z');
        final recent = ep(
          17,
          seconds: 310,
          date: freshDate ? '2026-10-25T00:02:00Z' : '2026-10-24T00:00:00Z',
        );
        final api = EmbyClient(
          client: MockClient(
            (request) async => response(
              jsonEncode({
                'Items': [
                  request.url.queryParameters['SortBy'] == 'DatePlayed'
                      ? ep(17, seconds: 310, date: '2026-10-25T00:02:00Z').data
                      : stale.data,
                ],
              }),
              200,
            ),
          ),
        )..session = syntheticSession();
        final seed = HomeFeed(api, store);
        await prefs.setString(
          seed.cacheKey,
          jsonEncode({
            'items': [
              {
                'item': recent.data,
                'observedAt': DateTime.now()
                    .subtract(const Duration(minutes: 2))
                    .toIso8601String(),
              },
            ],
          }),
        );
        seed.dispose();
        final feed = HomeFeed(api, store);
        try {
          await feed.refreshResume(force: true);
          expect(
            feed.resume.single.id,
            'e14',
            reason:
                'A local observation cannot displace the server Resume result.',
          );
        } finally {
          feed.dispose();
          api.close();
          store.dispose();
        }
      },
    );
  }
  for (final released in [true, false]) {
    test(
      'legacy local observations cannot override server snapshots after restart, delivered149=$released',
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
    'raw Resume episode and position survive store/API/feed recreation despite different detail history',
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
              'An overwrite update restores the server snapshot, not a substituted history row.',
        );
        expect(feed.resume.single.resume, stale.resume);
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
        final oldButtons = tester.getCenter(find.byTooltip('快进 10 秒')).dy;
        final oldTop = tester
            .getCenter(find.byKey(const Key('playback-timeline')))
            .dy;
        await tester.pumpWidget(chrome(false));
        await tester.pumpAndSettle();
        final newTop = tester
            .getCenter(find.byKey(const Key('playback-timeline')))
            .dy;
        expect(newTop - oldTop, phone ? 8 : 0);
        expect(
          tester.getCenter(find.byTooltip('快进 10 秒')).dy - oldButtons,
          0,
          reason:
              'Only the phone timeline may move; transport buttons must keep delivered149 positions.',
        );
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
            'build/playback151/previews/controls-${phone ? 'phone' : 'tablet'}.png',
          )..parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
