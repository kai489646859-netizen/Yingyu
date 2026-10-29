import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/episode_neighbors.dart';
import 'package:yingyu/ui/poster_art.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  test(
    'refresh defaults to 5 minutes; explicit prior choices survive',
    () async {
      expect(BrowsePreferences(prefs).minutes, 5);
      await BrowsePreferences(prefs).setMinutes(5);
      expect(BrowsePreferences(prefs).minutes, 5);
      await prefs.setInt('yingyu.browse.minutes.v1', -1);
      expect(BrowsePreferences(prefs).minutes, 5);
    },
  );
  test(
    'pinyin is the catalogue default and an explicit sort survives restart',
    () async {
      final p = BrowsePreferences(prefs);
      expect(p.sort, 'alphabet');
      for (final value in BrowsePreferences.sorts) {
        await p.setSort(value);
        expect(BrowsePreferences(prefs).sort, value);
      }
      await p.setSort('unknown');
      expect(p.sort, 'alphabet');
      p.dispose();
    },
  );
  test(
    'cache 1/5/10 GB and interface preferences persist, rejecting invalid values',
    () async {
      final p = InterfacePreferences(prefs);
      expect(p.cacheGB, 5);
      for (final size in [1, 5, 10]) {
        await p.setCacheGB(size);
        expect(InterfacePreferences(prefs).cacheGB, size);
      }
      await p.setCacheGB(9);
      expect(p.cacheGB, 10);
      await p.setReducedMotion(true);
      expect(InterfacePreferences(prefs).reducedMotion, true);
    },
  );
  test(
    'episode and season poster URL reuses series file without changing media identity',
    () {
      final api = EmbyClient()..session = syntheticSession();
      final series = MediaItem({
        'Id': 'series',
        'Type': 'Series',
        'ImageTags': {'Primary': 'cover'},
      });
      final episode = MediaItem({
        'Id': 'e2',
        'Type': 'Episode',
        'SeriesId': 'series',
        'SeriesPrimaryImageTag': 'cover',
        'ImageTags': {'Primary': 'landscape-still'},
      });
      expect(posterAspectRatio, 2 / 3);
      expect(posterUrl(api, episode), api.imageUrl(series));
      expect(episode.id, 'e2');
      final noTag = MediaItem({
        'Id': 'e3',
        'Type': 'Episode',
        'SeriesId': 'series',
      });
      expect(posterUrl(api, noTag, series: series), api.imageUrl(series));
      expect(
        Uri.parse(posterUrl(api, noTag)!).path,
        endsWith('/Items/series/Images/Primary'),
      );
      final query = Uri.parse(posterUrl(api, episode)!).queryParameters;
      expect(query['maxWidth'], '360');
      expect(query['quality'], '85');
      api.close();
    },
  );
  test(
    'adjacent episodes preserve server order and exact IDs including season boundaries',
    () async {
      final items = [
        for (final id in ['season1-last', 'current', 'season2-first'])
          {'Id': id, 'Type': 'Episode', 'SeriesId': 's'},
      ];
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          expect(r.url.path, endsWith('/Shows/s/Episodes'));
          expect(r.url.queryParameters['AdjacentTo'], 'current');
          return response(jsonEncode({'Items': items}), 200);
        }),
      )..session = syntheticSession();
      final neighbors = await EpisodeNeighbors.load(api, MediaItem(items[1]));
      expect(neighbors.previous?.id, 'season1-last');
      expect(neighbors.next?.id, 'season2-first');
      await EpisodeNeighbors.load(
        api,
        MediaItem({'Id': 'movie', 'Type': 'Movie'}),
      );
      expect(calls, 1);
      items.removeAt(1);
      await expectLater(
        EpisodeNeighbors.load(
          api,
          MediaItem({'Id': 'current', 'Type': 'Episode', 'SeriesId': 's'}),
        ),
        throwsA(isA<AppFailure>()),
      );
      api.close();
    },
  );
  testWidgets(
    'one glass capsule moves through intermediate positions and matches each target',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: StatefulBuilder(
                builder: (context, set) => GlassNavigation(
                  index: selected,
                  onChanged: (value) => set(() => selected = value),
                ),
              ),
            ),
          ),
        ),
      );
      final pill = find.byKey(const Key('navigation-glass-indicator'));
      final start = tester.getCenter(pill).dx;
      await tester.tap(find.byKey(const ValueKey('navigation-tab-3')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 170));
      final mid = tester.getCenter(pill).dx;
      expect(mid, greaterThan(start));
      expect(
        mid,
        lessThan(
          tester.getCenter(find.byKey(const ValueKey('navigation-tab-3'))).dx,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(pill).dx,
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('navigation-tab-1'))).dx,
          .01,
        ),
      );
      tester.view.physicalSize = const Size(900, 1280);
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(pill).dx,
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('navigation-tab-1'))).dx,
          .01,
        ),
      );
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'clear browse cache requires confirmation; cancel preserves data and preferences',
    (tester) async {
      final api = EmbyClient()..session = syntheticSession();
      final cache = BrowseCache(prefs);
      final repo = BrowseRepository(api, cache, BrowsePreferences(prefs));
      final store = AppStore(prefs);
      await cache.put(
        'test',
        ItemPage([
          MediaItem({'Id': 'sample'}),
        ], 1),
        DateTime.now(),
      );
      await prefs.setString('unrelated-setting', 'retained');
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: SettingsPage(store: store, browse: repo),
          ),
        ),
      );
      await tester.scrollUntilVisible(find.text('清理浏览资料缓存'), 250);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('clear-browse-cache-arrow')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(cache.get('test'), isNotNull);
      await tester.tap(find.byKey(const Key('clear-browse-cache-arrow')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理'));
      await tester.pumpAndSettle();
      expect(cache.get('test'), isNull);
      expect(prefs.getString('unrelated-setting'), 'retained');
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      store.dispose();
      api.close();
    },
  );
}
