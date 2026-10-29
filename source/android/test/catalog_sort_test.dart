import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/catalog_sort.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/browse_menu.dart';
import 'package:yingyu/ui/scroll_behavior.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'offline_settle.dart';
import 'scroll_affordance_test.dart' show fonts;

List<MediaItem> fixtures() => prepareCatalog([
  MediaItem({
    'Id': 'a',
    'Name': '阿丽塔',
    'Type': 'Movie',
    'DateCreated': '2022-01-01T00:00:00Z',
    'PremiereDate': '2022-01-02T00:00:00Z',
    'CommunityRating': 9.5,
    'UserData': {'Played': false},
  }),
  MediaItem({
    'Id': 'b',
    'Name': '白日梦',
    'Type': 'Movie',
    'DateCreated': '2024-01-01T00:00:00Z',
    'PremiereDate': '2023-01-03T00:00:00Z',
    'CommunityRating': 10,
    'UserData': {'Played': true},
  }),
  MediaItem({
    'Id': 'z',
    'Name': '最后一部',
    'Type': 'Movie',
    'DateCreated': '2021-01-01T00:00:00Z',
    'PremiereDate': '2021-01-01T00:00:00Z',
    'CommunityRating': 0,
    'UserData': {'Played': false},
  }),
  for (var i = 0; i < 80; i++)
    MediaItem({
      'Id': 'm$i',
      'Name': 'Movie ${i.toString().padLeft(2, '0')}',
      'Type': 'Movie',
    }),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all four criteria and both directions use real values and keep unknowns last',
    () {
      final source = fixtures();
      final originalIds = source.map((item) => item.id).toList();
      for (final sort in catalogSortLabels.keys) {
        for (final descending in [false, true]) {
          final result = orderCatalog((source, sort, descending));
          expect(result.map((item) => item.id).toSet(), originalIds.toSet());
          expect(
            result.first.id,
            sort == 'alphabet'
                ? (descending ? 'z' : 'a')
                : (descending ? 'b' : 'z'),
          );
          if (sort != 'alphabet') expect(result.last.id, 'm79');
        }
      }
      expect(source.map((item) => item.id), originalIds);
      final missing = orderCatalog((
        prepareCatalog([
          MediaItem({
            'Id': 'bad',
            'Name': 'Alpha',
            'CommunityRating': 'NaN',
            'PremiereDate': 'bad',
          }),
          MediaItem({
            'Id': 'valid',
            'Name': 'Zulu',
            'CommunityRating': 0,
            'PremiereDate': '2020-01-01',
          }),
        ]),
        'CommunityRating',
        false,
      ));
      expect(missing.first.id, 'valid');
    },
  );

  test(
    'refresh retains deterministic order while exposing newer progress and resorting changed ratings',
    () {
      final ordering = CatalogOrdering();
      final source = fixtures();
      final old = ordering.apply(source, 'CommunityRating', true);
      final changed = [
        for (final item in source.reversed)
          MediaItem({
            ...item.data,
            'UserData': {'Played': true},
          }),
      ];
      final refreshed = ordering.apply(changed, 'CommunityRating', true);
      expect(refreshed.map((item) => item.id), old.map((item) => item.id));
      expect(
        refreshed.every(
          (item) => object(item.data['UserData'])['Played'] == true,
        ),
        isTrue,
      );
      final promoted = [
        for (final item in source)
          if (item.id == 'a')
            MediaItem({...item.data, 'CommunityRating': 10.5})
          else
            item,
      ];
      expect(ordering.apply(promoted, 'CommunityRating', true).first.id, 'a');
    },
  );

  test(
    'default, legacy choices and both sort controls persist independently of account data',
    () async {
      for (final old in [
        null,
        'alphabet',
        'SortName',
        '',
        'DateCreated',
        'CommunityRating',
        'ProductionYear',
      ]) {
        SharedPreferences.setMockInitialValues({
          'yingyu.browse.sort.v1': ?old,
          'synthetic.account': 'untouched',
        });
        final prefs = await SharedPreferences.getInstance();
        var preferences = BrowsePreferences(prefs);
        expect(preferences.sort, normalizeCatalogSort(old));
        expect(
          preferences.descending,
          ['DateCreated', 'CommunityRating', 'ProductionYear'].contains(old),
        );
        for (final sort in catalogSortLabels.keys) {
          for (final descending in [true, false]) {
            await preferences.setSort(sort, descending: descending);
            preferences.dispose();
            preferences = BrowsePreferences(prefs);
            expect(preferences.sort, sort);
            expect(preferences.descending, descending);
          }
        }
        expect(prefs.getString('synthetic.account'), 'untouched');
        preferences.dispose();
      }
    },
  );

  test(
    'premiere dates survive the metadata-only disk cache, without media URLs or headers',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final source = MediaItem({
        ...fixtures().first.data,
        'Path': 'https://synthetic.invalid/movie',
        'RequiredHttpHeaders': {'Secret': 'synthetic'},
      });
      await BrowseCache(
        prefs,
      ).put('test', ItemPage([source], 1), DateTime.now());
      final restored = BrowseCache(prefs).get('test')!.items.single;
      expect(restored.data['PremiereDate'], source.data['PremiereDate']);
      expect(restored.data.containsKey('Path'), isFalse);
      expect(restored.data.containsKey('RequiredHttpHeaders'), isFalse);
    },
  );

  testWidgets(
    'old catalogue fills premiere dates once and retains cached rows while refreshing',
    (tester) async {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Persons')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          if (request.url.path.endsWith('/Views')) {
            return response('{"Items":[]}', 200);
          }
          calls++;
          return response(
            jsonEncode({
              'Items': fixtures().map((item) => item.data).toList(),
              'TotalRecordCount': 83,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      await repo.cache.put(
        repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
        ItemPage([
          for (final item in fixtures())
            MediaItem({...item.data}..remove('PremiereDate')),
        ], 83),
        DateTime.now(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      expect(calls, 0);
      expect(find.text('阿丽塔'), findsOneWidget);
      await tester.tap(find.byKey(const Key('library-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort:PremiereDate')));
      await settleOffline(tester);
      expect(calls, 1);
      expect(
        tester.widgetList<MediaCard>(find.byType(MediaCard)).first.item.id,
        'z',
      );
      for (final value in [
        'order:descending',
        'sort:DateCreated',
        'sort:PremiereDate',
      ]) {
        await tester.tap(find.byKey(const Key('library-sort')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(value)));
        await settleOffline(tester);
      }
      expect(calls, 1);
      expect(
        repo
            .peekSharedCatalogue(null)!
            .items
            .every((item) => item.data['_YingyuSortMetadataV1'] == true),
        isTrue,
      );
      // A different partition can still contain legacy rows after the all-view
      // cache has already been updated. Its first date sort must also fill once.
      await repo.cache.put(
        repo.key(BrowseRepository.catalogueKey('older-partition', 'alphabet')),
        ItemPage([
          for (final item in fixtures())
            MediaItem({...item.data}..remove('PremiereDate')),
        ], 83),
        DateTime.now(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(
              api: api,
              browse: repo,
              onItem: (_) async {},
              requestedLibrary: MediaItem({
                'Id': 'older-partition',
                'Name': '旧分库',
              }),
              libraryRequest: 1,
            ),
          ),
        ),
      );
      await settleOffline(tester);
      expect(calls, 2);
      expect(
        tester.widgetList<MediaCard>(find.byType(MediaCard)).first.item.id,
        'b',
      );
      expect(
        repo
            .peekSharedCatalogue('older-partition')!
            .items
            .every((item) => item.data['_YingyuSortMetadataV1'] == true),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
    },
  );

  testWidgets('sorting popover keeps the initial metadata request alive', (
    tester,
  ) async {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final pending = Completer<void>();
    var calls = 0;
    final api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/Persons')) {
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }
        if (request.url.path.endsWith('/Views')) {
          return response('{"Items":[]}', 200);
        }
        calls++;
        await pending.future;
        return response(
          jsonEncode({
            'Items': fixtures().map((item) => item.data).toList(),
            'TotalRecordCount': 83,
          }),
          200,
        );
      }),
    )..session = syntheticSession();
    final repo = BrowseRepository(
      api,
      BrowseCache(prefs),
      BrowsePreferences(prefs),
      spacing: Duration.zero,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const Key('library-sort')));
    await tester.pump(const Duration(milliseconds: 400));
    pending.complete();
    await settleOffline(tester);
    expect(find.text('排序依据'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sort:PremiereDate')));
    await settleOffline(tester);
    expect(calls, 1);
    expect(
      tester.widgetList<MediaCard>(find.byType(MediaCard)).first.item.id,
      'z',
    );
    await tester.pumpWidget(const SizedBox());
    repo.dispose();
    api.close();
  });

  for (final size in [const Size(412, 892), const Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'reference sort popover, cache reuse and descending rail $size $brightness',
        (tester) async {
          final shadows = debugDisableShadows;
          debugDisableShadows = false;
          try {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            VisibilityDetectorController.instance.updateInterval =
                Duration.zero;
            await fonts();
            SharedPreferences.setMockInitialValues({});
            final prefs = await SharedPreferences.getInstance();
            var calls = 0;
            final api = EmbyClient(
              client: MockClient((request) async {
                if (request.url.path.endsWith('/Persons')) {
                  return response('{"Items":[],"TotalRecordCount":0}', 200);
                }
                if (request.url.path.endsWith('/Views')) {
                  return response('{"Items":[]}', 200);
                }
                calls++;
                expect(request.url.path.endsWith('/Items'), isTrue);
                return response(
                  jsonEncode({
                    'Items': fixtures().map((i) => i.data).toList(),
                    'TotalRecordCount': 83,
                  }),
                  200,
                );
              }),
            )..session = syntheticSession();
            final repo = BrowseRepository(
              api,
              BrowseCache(prefs),
              BrowsePreferences(prefs),
              spacing: Duration.zero,
            );
            final repaint = GlobalKey();
            await tester.pumpWidget(
              MaterialApp(
                theme: appTheme(brightness),
                scrollBehavior: const AppScrollBehavior(),
                builder: (_, child) =>
                    RepaintBoundary(key: repaint, child: child!),
                home: Scaffold(
                  body: LibraryPage(
                    api: api,
                    browse: repo,
                    onItem: (_) async {},
                  ),
                ),
              ),
            );
            await settleOffline(tester);
            expect(calls, 1);
            final viewport = find.byType(CustomScrollView);
            final scroll = tester
                .widget<CustomScrollView>(viewport)
                .controller!;
            final bar = find.byWidgetPredicate(
              (w) =>
                  w is RawScrollbar &&
                  w.controller?.positions.contains(scroll.position) == true,
            );
            expect(tester.getRect(bar).right, size.width);
            expect(tester.widget<RawScrollbar>(bar).crossAxisMargin, 0);
            for (final sort in catalogSortLabels.keys) {
              await tester.tap(find.byKey(const Key('library-sort')));
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(ValueKey('sort:$sort')));
              await settleOffline(tester);
              for (final descending in [false, true]) {
                await tester.tap(find.byKey(const Key('library-sort')));
                await tester.pumpAndSettle();
                await tester.tap(
                  find.byKey(
                    ValueKey(
                      'order:${descending ? 'descending' : 'ascending'}',
                    ),
                  ),
                );
                await settleOffline(tester);
                final first = tester
                    .widgetList<MediaCard>(find.byType(MediaCard))
                    .first
                    .item
                    .id;
                expect(
                  first,
                  sort == 'alphabet'
                      ? (descending ? 'z' : 'a')
                      : (descending ? 'b' : 'z'),
                );
                expect(
                  calls,
                  1,
                  reason:
                      'Sorting the complete cache must not read the server again',
                );
              }
            }
            await tester.tap(find.byKey(const Key('library-sort')));
            await tester.pumpAndSettle();
            final criteria = find.byWidgetPredicate(
              (item) =>
                  item.key is ValueKey<String> &&
                  (item.key as ValueKey<String>).value.startsWith('sort:'),
            );
            expect(
              tester.widgetList(criteria).first.key,
              const ValueKey('sort:alphabet'),
            );
            await tester.tap(find.byKey(const ValueKey('sort:alphabet')));
            await settleOffline(tester);
            expect(
              tester
                  .getRect(find.byKey(const ValueKey('alphabet-letter-Z')))
                  .top,
              lessThan(
                tester
                    .getRect(find.byKey(const ValueKey('alphabet-letter-A')))
                    .top,
              ),
            );
            await tester.tap(find.bySemanticsLabel('拼音 A'));
            await settleOffline(tester);
            expect(find.text('阿丽塔').hitTestable(), findsOneWidget);
            expect(scroll.offset, greaterThan(0));
            await tester.tap(find.byKey(const Key('library-sort')));
            await tester.pumpAndSettle();
            expect(find.text('排序依据'), findsOneWidget);
            expect(find.text('排序方式'), findsOneWidget);
            expect(find.textContaining('首字母拼音'), findsNothing);
            expect(find.text('观看状态'), findsOneWidget);
            expect(find.byIcon(CupertinoIcons.check_mark), findsNothing);
            expect(
              tester
                  .widgetList<BrowseMenuChoice>(find.byType(BrowseMenuChoice))
                  .where((row) => row.selected),
              hasLength(3),
            );
            expect(find.byKey(const Key('browse-options')), findsNothing);
            final panel = tester.getRect(
              find
                  .ancestor(
                    of: find.text('排序依据'),
                    matching: find.byType(Material),
                  )
                  .first,
            );
            final button = tester.getRect(
              find.byKey(const Key('library-sort')),
            );
            final search = tester.getRect(
              find.byKey(const Key('library-search')),
            );
            expect(button.center.dy, closeTo(search.center.dy, 1));
            expect(button.left, greaterThan(search.right));
            expect(panel.right, closeTo(button.right + 7, 12));
            expect(panel.top, greaterThan(button.bottom));
            expect(panel.left, greaterThanOrEqualTo(0));
            expect(panel.bottom, lessThanOrEqualTo(size.height));
            expect(panel.width, lessThanOrEqualTo(100));
            for (final entry in catalogSortLabels.values) {
              final paragraph = tester.renderObject<RenderParagraph>(
                find.text(entry),
              );
              expect(paragraph.didExceedMaxLines, isFalse);
              expect(tester.widget<Text>(find.text(entry)).maxLines, 1);
            }
            expect(panel.height, lessThanOrEqualTo(480));
            // Capture the overlay as well as the page, using the render root.
            final boundary =
                repaint.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            await tester.runAsync(() async {
              final image = await boundary.toImage();
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/ui-previews/$appVersion-sort-menu-${size.width.toInt()}-${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(png!.buffer.asUint8List());
              image.dispose();
            });
            // System back dismisses only the popover and preserves selection/offset.
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.text('排序依据'), findsNothing);
            expect(scroll.offset, greaterThan(0));
            await tester.tap(find.byKey(const Key('library-sort')));
            await tester.pumpAndSettle();
            await tester.tap(find.text('已看'));
            await settleOffline(tester);
            expect(
              tester
                  .widgetList<MediaCard>(find.byType(MediaCard))
                  .map((c) => c.item.id),
              ['b'],
            );
            expect(calls, 1);
            await tester.enterText(
              find.byKey(const Key('library-search')),
              '白日梦',
            );
            await settleOffline(tester);
            for (final status in ['false', 'all']) {
              await tester.tap(find.byKey(const Key('library-sort')));
              await tester.pumpAndSettle();
              await tester.ensureVisible(
                find.byKey(ValueKey('played:$status')),
              );
              await tester.tap(find.byKey(ValueKey('played:$status')));
              await settleOffline(tester);
              final shown = tester
                  .widgetList<MediaCard>(find.byType(MediaCard))
                  .map((c) => c.item.id);
              expect(shown.contains('b'), status == 'all');
              expect(calls, 1);
              expect(repo.preferences.sort, 'alphabet');
              expect(repo.preferences.descending, isTrue);
            }
            await tester.pumpWidget(const SizedBox());
            repo.dispose();
            api.close();
            expect(tester.takeException(), isNull);
          } finally {
            debugDisableShadows = shadows;
          }
        },
      );
    }
  }
}
