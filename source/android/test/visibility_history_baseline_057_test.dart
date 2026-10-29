import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/home_order.dart';
import 'core_test.dart' show response, syntheticSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'refresh preserves verified visible content while hidden scope is resolving',
    () async {
      final order = HomeOrder(await SharedPreferences.getInstance()),
          a = syntheticSession();
      final row = MediaItem({
        'Id': 'public',
        'Type': 'Movie',
        '_YingyuLibraryIdsV1': ['public-view'],
      });
      await order.saveHidden(a, {'private-view'});
      order.resolveMembership(a, [row], ['public-view', 'private-view']);
      order.beginResolution(a);
      expect(order.allows(a, row), true);
      expect(
        order.allows(a, MediaItem({'Id': 'unknown', 'Type': 'Movie'})),
        false,
      );
    },
  );
  test(
    'normal complete directory retires an absent movie with no ID probes',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          order = HomeOrder(await SharedPreferences.getInstance());
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          expect(r.url.queryParameters['Ids'], isNull);
          return response(
            jsonEncode({'Items': [], 'TotalRecordCount': 0}),
            200,
          );
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      final old = MediaItem({'Id': 'old', 'Type': 'Movie'});
      await repo.cache.put(
        repo.key('cached'),
        ItemPage([old], 1),
        DateTime.now(),
      );
      await repo.catalogue(force: true);
      expect(calls, 1);
      expect(order.removals.allows(api.session!, old), false);
      repo.dispose();
      api.close();
    },
  );
  testWidgets('section switch text reflects hidden state', (tester) async {
    final store = AppStore(await SharedPreferences.getInstance());
    final api = EmbyClient()..session = syntheticSession();
    final feed = HomeFeed(api, store);
    feed.sections = [
      HomeSection(MediaItem({'Id': 'a', 'Name': 'a'})),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HomeOrderPage(feed: feed)),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('home-visible-a')));
    await tester.pumpAndSettle();
    expect(find.text('应用内隐藏'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    feed.dispose();
    api.close();
    store.dispose();
  });
}
