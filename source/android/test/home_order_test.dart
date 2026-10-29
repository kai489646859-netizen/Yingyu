import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise slow/failed persistence without a device or real account.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/home_order.dart';
import 'core_test.dart' show syntheticSession;

class DelayedHomePreferences extends InMemorySharedPreferencesStore {
  DelayedHomePreferences() : super.withData({});
  final gates = <Completer<bool>>[];
  final orders = <List<String>>[];
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.startsWith('flutter.yingyu.home.order.')) {
      final gate = Completer<bool>();
      gates.add(gate);
      orders.add(List<String>.from(value as List));
      if (!await gate.future) return false;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  test(
    'home order survives restart, isolates accounts, appends new libraries and restores reappearing IDs',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final order = HomeOrder(prefs),
          a = syntheticSession(),
          b = syntheticSession('http://127.0.0.1:10');
      expect(order.apply(a, ['shows', 'anime', 'movies'], (s) => s), [
        'shows',
        'anime',
        'movies',
      ]);
      await order.save(a, ['anime', 'shows', 'movies']);
      final reopened = HomeOrder(prefs);
      expect(reopened.apply(a, ['shows', 'anime', 'movies', 'new'], (s) => s), [
        'anime',
        'shows',
        'movies',
        'new',
      ]);
      expect(reopened.apply(a, ['shows', 'movies'], (s) => s), [
        'shows',
        'movies',
      ]);
      expect(reopened.apply(a, ['shows', 'anime', 'movies'], (s) => s), [
        'anime',
        'shows',
        'movies',
      ]);
      expect(reopened.apply(b, ['shows', 'anime', 'movies'], (s) => s), [
        'shows',
        'anime',
        'movies',
      ]);
      order.dispose();
      reopened.dispose();
    },
  );
  testWidgets(
    'consecutive drags keep geometry and handles during slow saves; failed latest save can retry',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final platform = DelayedHomePreferences();
      final original = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = platform;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      final store = AppStore(await SharedPreferences.getInstance());
      final api = EmbyClient()..session = syntheticSession();
      final feed = HomeFeed(api, store);
      feed.sections = [
        for (final id in ['shows', 'anime', 'movies'])
          HomeSection(MediaItem({'Id': id, 'Name': id})),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HomeOrderPage(feed: feed)),
        ),
      );
      final list = find.byKey(const Key('home-section-order-list'));
      final originalRect = tester.getRect(list);
      Future<void> dragAbove(String from, String to) async {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('home-order-handle-$from'))),
        );
        await tester.pump();
        await gesture.moveTo(
          tester.getCenter(find.byKey(ValueKey('home-order-handle-$to'))),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
      }

      await dragAbove('anime', 'shows');
      expect(platform.orders, [
        ['anime', 'shows', 'movies'],
      ]);
      expect(tester.getRect(list), originalRect);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(
        tester
            .widgetList<ReorderableDragStartListener>(
              find.byType(ReorderableDragStartListener),
            )
            .every((h) => h.enabled),
        isTrue,
      );
      await dragAbove('movies', 'anime');
      expect(
        platform.orders.length,
        1,
        reason: 'new drag stays responsive while writes remain serialized',
      );
      expect(tester.getRect(list), originalRect);
      platform.gates.first.complete(true);
      await tester.pump();
      expect(platform.orders.last, ['movies', 'anime', 'shows']);
      platform.gates.last.complete(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('当前设置尚未全部保存'), findsOneWidget);
      await tester.tap(find.text('重试保存'));
      await tester.pump();
      expect(platform.orders.last, ['movies', 'anime', 'shows']);
      platform.gates.last.complete(true);
      await tester.pumpAndSettle();
      expect(tester.getRect(list), originalRect);
      await store.prefs.reload();
      expect(HomeOrder(store.prefs).read(feed.account), [
        'movies',
        'anime',
        'shows',
      ]);
      await tester.pumpWidget(const SizedBox());
      feed.dispose();
      api.close();
      store.log.dispose();
      store.dispose();
    },
  );
  testWidgets(
    'drag handle reorders real feed and keeps continue watching untouched',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = EmbyClient()..session = syntheticSession();
      final feed = HomeFeed(api, store);
      feed.sections = [
        for (final entry in {
          'shows': '剧集',
          'anime': '动漫',
          'movies': '电影',
        }.entries)
          HomeSection(MediaItem({'Id': entry.key, 'Name': entry.value})),
      ];
      final resume = MediaItem({'Id': 'resume', 'Name': '正在观看'});
      feed.resume = [resume];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: HomeOrderPage(feed: feed)),
        ),
      );
      final anime = find.byKey(const ValueKey('home-order-handle-anime'));
      final drag = await tester.startGesture(tester.getCenter(anime));
      await tester.pump();
      await drag.moveTo(
        tester.getCenter(find.byKey(const ValueKey('home-order-handle-shows'))),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await drag.up();
      await tester.pumpAndSettle();
      expect(feed.displaySections.map((s) => s.library.id), [
        'anime',
        'shows',
        'movies',
      ]);
      expect(feed.resume.single, same(resume));
      await tester.pumpWidget(const SizedBox());
      feed.dispose();
      api.close();
      store.log.dispose();
      store.dispose();
    },
  );
}
