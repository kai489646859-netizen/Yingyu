import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'first cold homepage shows cached public sections after live permission validation',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      final account = syntheticSession(), cache = BrowseCache(prefs);
      final library = MediaItem({
        'Id': 'public',
        'Name': '公开电影',
        'Type': 'CollectionFolder',
      });
      final movie = MediaItem({
        'Id': 'movie',
        'Name': '首次进入应显示',
        'Type': 'Movie',
      });
      String key(String query) =>
          jsonEncode([account.base.toString(), account.userId, query]);
      await cache.put(key('views'), ItemPage([library], 1), DateTime.now());
      await cache.put(
        key('latest:public'),
        ItemPage([movie], 1),
        DateTime.now(),
      );
      await cache.put(key('resume:0:18'), ItemPage([], 0), DateTime.now());
      await store.homeOrder.saveHidden(account, {'revoked'});
      final entered = Completer<void>(), gate = Completer<void>();
      var inventories = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Views')) {
            if (!entered.isCompleted) entered.complete();
            await gate.future;
            return response(
              jsonEncode({
                'Items': [library.data],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/Latest')) {
            return response(jsonEncode([movie.data]), 200);
          }
          if (r.url.path.endsWith('/Resume')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          inventories++;
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      )..session = account;
      final repo = BrowseRepository(
        api,
        cache,
        BrowsePreferences(prefs),
        visibility: store.homeOrder,
        spacing: Duration.zero,
      );
      final feed = HomeFeed(api, store, browse: repo);
      final first = feed.refresh();
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      gate.complete();
      await first;
      expect(feed.error, isNull);
      expect(feed.displaySections, hasLength(1));
      expect(
        store.homeOrder
            .visible(account, feed.displaySections.single.items)
            .map((i) => i.id),
        ['movie'],
        reason:
            'the initial page must show the section before any navigation or second refresh',
      );
      expect(inventories, 0);
      feed.dispose();
      repo.dispose();
      api.close();
      store.dispose();
    },
  );
}
