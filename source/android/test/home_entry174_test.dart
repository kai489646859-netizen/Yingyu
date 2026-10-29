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
import 'package:yingyu/ui/home.dart';
import 'core_test.dart' show response, syntheticSession;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_settle.dart' show settleOffline;

void main() {
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  testWidgets(
    'cold home and foreground entry read live Resume despite fresh browse cache, without manual refresh',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      var version = 1, reads = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Views')) {
            return response('{"Items":[]}', 200);
          }
          if (r.url.path.endsWith('/Resume')) {
            reads++;
            return response(
              jsonEncode({
                'Items': [
                  {
                    'Id': 'movie$version',
                    'Name': '合成$version',
                    'Type': 'Movie',
                    'UserData': {
                      'PlaybackPositionTicks': ticks(
                        Duration(minutes: version),
                      ),
                    },
                  },
                ],
              }),
              200,
            );
          }
          return response('{}', 404);
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      await repo.resume(force: true);
      expect(reads, 1);
      final feed = HomeFeed(api, store, browse: repo);
      expect(feed.resume.single.id, 'movie1');
      version = 2;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeDashboard(
              feed: feed,
              active: true,
              onItem: (_) async {},
              onPlay: (_) async {},
            ),
          ),
        ),
      );
      await settleOffline(tester);
      expect(
        feed.resume.single.id,
        'movie2',
        reason:
            'HomeDashboard.initState must fetch live progress even inside the cache TTL.',
      );
      expect(reads, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // HomePage owns this suspension/activation in the real app; Dashboard owns the automatic refresh.
      repo.suspend();
      feed.suspend();
      version = 3;
      repo.activate();
      feed.activate();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settleOffline(tester);
      expect(feed.resume.single.id, 'movie3');
      expect(reads, 3);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      feed.dispose();
      repo.dispose();
      api.close();
      store.dispose();
    },
  );
}
