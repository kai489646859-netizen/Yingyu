import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/library_layout.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, syntheticSession;

MediaItem focusEpisode(int n, DateTime date, {bool completed = false}) =>
    MediaItem({
      'Id': 'ep$n',
      'Type': 'Episode',
      'Name': '第 $n 集',
      'SeriesId': 'series',
      'SeasonId': 's1',
      'ParentIndexNumber': 1,
      'IndexNumber': n,
      'RunTimeTicks': ticks(const Duration(minutes: 30, seconds: 3)),
      'UserData': {
        'LastPlayedDate': date.toIso8601String(),
        'Played': completed,
        'PlaybackPositionTicks': completed
            ? 0
            : ticks(const Duration(minutes: 25, seconds: 48)),
      },
    });

EmbyClient wallApi() => EmbyClient(
  client: MockClient((request) async {
    if (request.url.path.endsWith('/Views')) {
      return response('{"Items":[]}', 200);
    }
    return response(
      jsonEncode({
        'Items': [
          for (var i = 0; i < 240; i++)
            {
              'Id': 'm$i',
              'Type': 'Movie',
              'Name': '影片 ${i.toString().padLeft(3, '0')}',
            },
        ],
        'TotalRecordCount': 240,
      }),
      200,
    );
  }),
)..session = syntheticSession();

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  for (final remoteNumber in [4, 5]) {
    testWidgets(
      'partial fifth episode wins over fourth completion remote=$remoteNumber',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = AppStore(await SharedPreferences.getInstance());
        final now = DateTime.now().toUtc();
        final fourth = focusEpisode(
          4,
          now.subtract(const Duration(minutes: 20)),
          completed: true,
        );
        final fifth = focusEpisode(
          5,
          now.subtract(const Duration(minutes: 30)),
        );
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.queryParameters['SortBy'] == 'DatePlayed') {
              return response(
                jsonEncode({
                  'Items': [remoteNumber == 4 ? fourth.data : fifth.data],
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/Seasons')) {
              return response(
                '{"Items":[{"Id":"s1","Name":"第 1 季","IndexNumber":1}]}',
                200,
              );
            }
            if (request.url.path.endsWith('/Episodes')) {
              return response(
                jsonEncode({
                  'Items': [fourth.data, fifth.data],
                  'TotalRecordCount': 2,
                }),
                200,
              );
            }
            if (request.url.path.endsWith('/series')) {
              return response(
                '{"Id":"series","Type":"Series","Name":"合成剧集"}',
                200,
              );
            }
            fail('Unexpected metadata request ${request.url.path}');
          }),
        )..session = syntheticSession();
        await store.completions.remember(api.session!, fourth, fourth.duration);
        final receiptKey = store.completions.key(api.session!, fourth.id);
        final receipt = object(jsonDecode(store.prefs.getString(receiptKey)!));
        await store.prefs.setString(
          receiptKey,
          jsonEncode({
            ...receipt,
            'at': now.subtract(const Duration(minutes: 10)).toIso8601String(),
          }),
        );
        final seed = HomeFeed(api, store);
        await store.prefs.setString(
          seed.cacheKey,
          jsonEncode({
            'items': [
              {
                'item': fifth.data,
                'observedAt': now
                    .subtract(const Duration(minutes: 2))
                    .toIso8601String(),
              },
            ],
          }),
        );
        seed.dispose();
        final feed = HomeFeed(api, store);
        final saved = {
          for (final key in store.prefs.getKeys())
            if (key != feed.verifiedHistoryKey) key: store.prefs.get(key),
        };
        addTearDown(() {
          feed.dispose();
          api.close();
          store.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DetailPage(
                item: MediaItem({'Id': 'series', 'Type': 'Series'}),
                api: api,
                store: store,
                resumeEpisode: feed.recentEpisode('series'),
                watchedEpisode: feed.lastWatchedEpisode,
                play: (_, _, _) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final selected = tester.widget<CupertinoButton>(
          find.byKey(const ValueKey('detail-episode-ep5')),
        );
        expect(
          selected.color,
          isNotNull,
          reason:
              'Partial viewing must determine focus, not the last natural EOF.',
        );
        expect(
          tester
              .widget<CupertinoButton>(
                find.byKey(const ValueKey('detail-episode-ep4')),
              )
              .color,
          isNull,
        );
        expect(find.text('上次观看：第 1 季 · 第 5 集'), findsOneWidget);
        expect(find.textContaining('看到 25:48 / 30:03'), findsNWidgets(2));
        expect({
          for (final key in store.prefs.getKeys())
            if (key != feed.verifiedHistoryKey) key: store.prefs.get(key),
        }, saved);
        final display = object(
          jsonDecode(store.prefs.getString(feed.verifiedHistoryKey)!),
        );
        expect(display['version'], 1);
        expect(
          objects(display['items']),
          isEmpty,
          reason:
              'No server Resume baseline was read; local detail focus is not a server snapshot.',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'settings choices open from the whole row and retain arrow placement',
    (tester) async {
      final store = AppStore(await SharedPreferences.getInstance());
      final api = wallApi();
      final repo = BrowseRepository(
        api,
        BrowseCache(store.prefs),
        BrowsePreferences(store.prefs),
        spacing: Duration.zero,
      );
      addTearDown(() {
        repo.dispose();
        api.close();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(store: store, browse: repo),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final title = find.text('媒体库展示');
      await tester.ensureVisible(title);
      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('library-display-setting-arrow')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    testWidgets('touching blank space dismisses search keyboard at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = wallApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(api: api, onItem: (_) async {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('library-search')));
      await tester.pumpAndSettle();
      final input = tester.widget<EditableText>(find.byType(EditableText));
      expect(input.focusNode.hasFocus, true);
      await tester.tapAt(Offset(size.width / 2, 25));
      await tester.pumpAndSettle();
      expect(input.focusNode.hasFocus, false);
      expect(tester.testTextInput.isVisible, false);
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final display in LibraryDisplay.values) {
    testWidgets('rotation retains top poster identity for ${display.name}', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = wallApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: LibraryPage(api: api, display: display, onItem: (_) async {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final old = LibraryGridMetrics(1280, 1, display);
      controller.jumpTo(
        12 * (old.rowHeight + old.spacing) + old.rowHeight * .2,
      );
      await tester.pumpAndSettle();
      final firstId = 'm${12 * old.columns}';
      for (final size in [
        const Size(800, 1280),
        const Size(1280, 800),
        const Size(600, 900),
        const Size(1280, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        final expected = find.byKey(ValueKey(firstId));
        expect(
          expected,
          findsOneWidget,
          reason:
              'Rotation must keep the same media ID, not the old pixel offset.',
        );
        final top = tester.getRect(find.byType(CustomScrollView)).top;
        final rect = tester.getRect(expected);
        expect(rect.top, lessThanOrEqualTo(top + 1));
        expect(rect.bottom, greaterThan(top));
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
