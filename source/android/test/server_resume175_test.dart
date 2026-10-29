import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/watch_progress.dart';
import 'core_test.dart' show response, syntheticSession;
import 'home175_test.dart' show ServerResumeFixture;
import 'offline_settle.dart' show settleOffline;
import 'player_episode_menu_test.dart' show fonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  test(
    'empty live server snapshot survives recreation without deleting a pending position',
    () async {
      final f = ServerResumeFixture(
        AppStore(await SharedPreferences.getInstance()),
      );
      await f.seed(const Duration(seconds: 2388));
      f.raw = [];
      await f.feed.refreshResume(force: true);
      expect(f.feed.resume, isEmpty);
      f.feed.dispose();
      f.feed = HomeFeed(f.api, f.store);
      expect(f.feed.resume, isEmpty);
      expect(
        f.store.localProgress(f.api.session!, f.eight.id),
        const Duration(seconds: 2388),
      );
      expect(f.feed.cachedItems.map((m) => m.id), contains('e8'));
      f.close();
    },
  );
  test(
    'server snapshot excludes media secrets, is account scoped, and corrupt JSON cannot revive local cards',
    () async {
      final f = ServerResumeFixture(
        AppStore(await SharedPreferences.getInstance()),
      );
      await f.seed(const Duration(seconds: 2388));
      f.raw = [
        MediaItem({
          ...f.movies().first.data,
          'Path': 'secret-path',
          'AccessToken': 'secret-token',
          'MediaSources': [
            {'Path': 'secret-source'},
          ],
        }),
      ];
      await f.feed.refreshResume(force: true);
      final key = f.feed.serverResumeKey;
      final saved = f.store.prefs.getString(key)!;
      expect(saved, isNot(contains('secret')));
      expect(saved, isNot(contains(f.api.session!.token)));
      expect(object(jsonDecode(saved))['version'], 1);
      f.feed.dispose();
      await f.store.prefs.setString(key, '{broken');
      f.feed = HomeFeed(f.api, f.store);
      expect(f.feed.resume, isEmpty);
      expect(
        f.store.localProgress(f.api.session!, f.eight.id),
        const Duration(seconds: 2388),
      );
      f.feed.dispose();
      f.api.session = syntheticSession('http://127.0.0.1:9/other-account');
      f.feed = HomeFeed(f.api, f.store);
      expect(f.feed.serverResumeKey, isNot(key));
      expect(f.feed.resume, isEmpty);
      f.close();
    },
  );
  testWidgets(
    'view-all second page keeps server checkpoints in actual UI state',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      final source = [
        for (var i = 0; i < 80; i++)
          MediaItem({
            'Id': 'm$i',
            'Name': '影片$i',
            'Type': 'Movie',
            'RunTimeTicks': ticks(const Duration(hours: 1)),
            'UserData': {
              'Played': false,
              'PlaybackPositionTicks': ticks(const Duration(seconds: 60)),
            },
          }),
      ];
      final calls = <int>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          if (!r.url.path.endsWith('/Resume')) return response('{}', 404);
          final start =
              int.tryParse(r.url.queryParameters['StartIndex'] ?? '0') ?? 0;
          final limit = int.parse(r.url.queryParameters['Limit']!);
          calls.add(start);
          return response(
            jsonEncode({
              'Items': source
                  .skip(start)
                  .take(limit)
                  .map((m) => m.data)
                  .toList(),
              'TotalRecordCount': 80,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final browse = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      final feed = HomeFeed(api, store, browse: browse);
      await feed.refreshResume(force: true);
      await store.saveProgress(
        api.session!,
        'm60',
        const Duration(seconds: 999),
        serverBaseline: source[60],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(
              api: api,
              browse: browse,
              resumeFeed: feed,
              onItem: (_) async {},
            ),
          ),
        ),
      );
      await settleOffline(tester);
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      controller.jumpTo(controller.position.maxScrollExtent);
      await settleOffline(tester);
      final dynamic page = tester.state(find.byType(LibraryPage));
      final row = (page.items as List<MediaItem>).singleWhere(
        (m) => m.id == 'm60',
      );
      expect(calls, contains(48));
      expect(row.resume, const Duration(seconds: 60));
      expect(
        WatchProgressState.resolve(row, api.session, store).position,
        const Duration(seconds: 60),
      );
      expect(
        store.resume(api.session!, source[60]).position,
        const Duration(seconds: 999),
      );
      await tester.pumpWidget(const SizedBox());
      await settleOffline(tester);
      feed.dispose();
      browse.dispose();
      api.close();
      store.dispose();
    },
  );
}
