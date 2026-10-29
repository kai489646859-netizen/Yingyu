import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/catalog_sort.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/server_connection.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/alphabet_rail.dart';
import 'package:yingyu/ui/library_layout.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'design_preview_test.dart' show ArtworkCache, paintArt, titles;
import 'offline_settle.dart';
import 'scroll_affordance_test.dart' show fonts;

List<MediaItem> sortingItems() => prepareCatalog([
  MediaItem({
    'Id': 'a',
    'Name': '远山 A',
    'ProductionYear': 2024,
    'DateCreated': '2020-01-01',
    'CommunityRating': 7,
  }),
  MediaItem({
    'Id': 'b',
    'Name': '远山 B',
    'ProductionYear': '1968',
    'DateCreated': '2022-01-01',
    'CommunityRating': '9.0',
  }),
  MediaItem({
    'Id': 'c',
    'Name': '远山 C',
    'ProductionYear': 2001,
    'DateCreated': '2021-01-01',
    'CommunityRating': 8,
  }),
  MediaItem({
    'Id': 'd',
    'Name': '其他 D',
    'ProductionYear': 2010,
    'DateCreated': '2023-01-01',
    'CommunityRating': 10,
  }),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(syntheticImagePaths);
  test(
    'release sorting uses the detail year, keeps unknowns last and updates year-only changes',
    () {
      final data = sortingItems();
      final ordering = CatalogOrdering();
      expect(ordering.apply(data, 'PremiereDate', false).map((i) => i.id), [
        'b',
        'c',
        'd',
        'a',
      ]);
      expect(ordering.apply(data, 'PremiereDate', true).map((i) => i.id), [
        'a',
        'd',
        'c',
        'b',
      ]);
      final changed = [
        for (final item in data)
          if (item.id == 'b')
            MediaItem({...item.data, 'ProductionYear': 2025})
          else
            item,
      ];
      expect(ordering.apply(changed, 'PremiereDate', true).first.id, 'b');
      final partial = prepareCatalog([
        MediaItem({'Id': 'unknown', 'Name': 'A', 'ProductionYear': 0}),
        MediaItem({'Id': 'date', 'Name': 'B', 'PremiereDate': '1999-08-01'}),
        MediaItem({
          'Id': 'year',
          'Name': 'C',
          'ProductionYear': 2001,
          'PremiereDate': '2026-08-01',
        }),
        MediaItem({
          'Id': 'tie',
          'Name': 'D',
          'ProductionYear': 2001,
          'PremiereDate': '2020-01-01',
        }),
      ]);
      expect(orderCatalog((partial, 'PremiereDate', false)).map((i) => i.id), [
        'date',
        'year',
        'tie',
        'unknown',
      ]);
      expect(orderCatalog((partial, 'PremiereDate', true)).map((i) => i.id), [
        'year',
        'tie',
        'date',
        'unknown',
      ]);
    },
  );

  for (final display in LibraryDisplay.values) {
    testWidgets(
      'all criteria reorder the real wall and multiple search matches in $display',
      (tester) async {
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/Views')) {
              return response('{"Items":[]}', 200);
            }
            expect(r.url.path.endsWith('/Items'), isTrue);
            calls++;
            return response(
              jsonEncode({
                'Items': sortingItems().map((i) => i.data).toList(),
                'TotalRecordCount': 4,
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
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: LibraryPage(
                api: api,
                browse: repo,
                display: display,
                onItem: (_) async {},
              ),
            ),
          ),
        );
        await settleOffline(tester);
        Future<void> pick(String key) async {
          await tester.tap(find.byKey(const Key('library-sort')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey(key)));
          await settleOffline(tester);
        }

        List<String> shown() => display == LibraryDisplay.standard
            ? tester
                  .widgetList<MediaCard>(find.byType(MediaCard))
                  .map((w) => w.item.id)
                  .toList()
            : tester
                  .widgetList<LibraryPosterCard>(find.byType(LibraryPosterCard))
                  .map((w) => w.item.id)
                  .toList();
        final expected = {
          'alphabet': ['d', 'a', 'b', 'c'],
          'PremiereDate': ['b', 'c', 'd', 'a'],
          'DateCreated': ['a', 'c', 'b', 'd'],
          'CommunityRating': ['a', 'c', 'b', 'd'],
        };
        for (final term in ['', '远山', 'yuanshan']) {
          await tester.enterText(find.byKey(const Key('library-search')), term);
          await settleOffline(tester);
          for (final sort in expected.keys) {
            await pick('sort:$sort');
            for (final descending in [false, true]) {
              await pick('order:${descending ? 'descending' : 'ascending'}');
              final order = descending
                  ? expected[sort]!.reversed
                  : expected[sort]!;
              expect(
                shown(),
                order.where((id) => term.isEmpty || id != 'd').toList(),
              );
              expect(
                calls,
                1,
                reason: 'Sorting and search reuse the full scoped catalogue',
              );
            }
          }
        }
        await tester.pumpWidget(const SizedBox());
        repo.dispose();
        api.close();
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final descending in [false, true]) {
    testWidgets(
      'short rail labels stay readable and dragging reaches every letter descending=$descending',
      (tester) async {
        final values = <String>[];
        const letters = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 24,
                  height: 180,
                  child: AlphabetRail(
                    available: letters.split('').toSet(),
                    descending: descending,
                    current: 'M',
                    onSelect: values.add,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final labels = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith(
                'compact-alphabet-letter-',
              ),
        );
        final rects = [
          for (final element in labels.evaluate())
            tester.getRect(find.byWidget(element.widget)),
        ]..sort((a, b) => a.top.compareTo(b.top));
        for (var i = 1; i < rects.length; i++) {
          expect(rects[i].top, greaterThanOrEqualTo(rects[i - 1].bottom));
        }
        final sequence = descending
            ? letters.split('').reversed.toList()
            : letters.split('');
        final gesture = await tester.startGesture(
          tester.getCenter(
            find.byKey(ValueKey('alphabet-letter-${sequence.first}')),
          ),
        );
        await tester.pump();
        for (final letter in sequence.skip(1)) {
          await gesture.moveTo(
            tester.getCenter(find.byKey(ValueKey('alphabet-letter-$letter'))),
          );
          await tester.pump(const Duration(milliseconds: 70));
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 150));
        expect(values, sequence);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  final sizes = {
    'small-phone': const Size(320, 640),
    'large-type': const Size(412, 915),
    'phone': const Size(412, 915),
    'phone-landscape': const Size(915, 412),
    'tablet-portrait': const Size(900, 1280),
    'tablet-landscape': const Size(1280, 800),
  };
  for (final size in sizes.entries) {
    final phone = size.value.shortestSide < 600;
    for (final mode in Brightness.values) {
      for (final display in LibraryDisplay.values) {
        testWidgets(
          'stable geometry, keyboard coverage and preview ${size.key} $mode $display',
          (tester) async {
            final oldShadows = debugDisableShadows;
            debugDisableShadows = false;
            final oldPoster = posterCache, oldArtwork = artworkCache;
            try {
              syntheticImagePaths();
              VisibilityDetectorController.instance.updateInterval =
                  Duration.zero;
              tester.view.physicalSize = size.value;
              tester.view.display.size = size.value;
              addTearDown(tester.view.display.resetSize);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              addTearDown(tester.view.resetViewInsets);
              if (size.key == 'large-type') {
                tester.platformDispatcher.textScaleFactorTestValue = 1.7;
                addTearDown(
                  tester.platformDispatcher.clearTextScaleFactorTestValue,
                );
              }
              await fonts();
              final files = await tester.runAsync(paintArt);
              posterCache = ArtworkCache(files!);
              artworkCache = posterCache;
              SharedPreferences.setMockInitialValues({});
              final prefs = await SharedPreferences.getInstance();
              final store = AppStore(prefs);
              await store.saveSession(syntheticSession());
              await store.setTheme(
                mode == Brightness.light ? ThemeMode.light : ThemeMode.dark,
              );
              final preferences = InterfacePreferences(prefs);
              await preferences.setLibraryDisplay(display);
              expect(InterfacePreferences(prefs).libraryDisplay, display);
              final data = [
                for (var i = 0; i < 100; i++)
                  {
                    'Id': 'poster-$i',
                    'Name': i < titles.length
                        ? titles[i]
                        : '资料 ${i.toString().padLeft(3, '0')}',
                    'Type': i % 2 == 0 ? 'Movie' : 'Series',
                    'ProductionYear': 2000 + i % 26,
                    'CommunityRating': 5.0 + i % 5,
                    'RecursiveItemCount': i % 2 == 1 ? 24 : 0,
                    'DateCreated':
                        '2026-01-${(1 + i % 28).toString().padLeft(2, '0')}',
                    'ImageTags': {'Primary': 'synthetic'},
                    'Overview': '合成影片资料，用于检查海报、片名和简介的横竖屏排版。',
                  },
              ];
              final api = EmbyClient(
                client: MockClient((r) async {
                  if (r.url.path.endsWith('/Users/synthetic-user')) {
                    return response('{"Id":"synthetic-user"}', 200);
                  }
                  if (r.url.path.endsWith('/Views')) {
                    return response(
                      '{"Items":[{"Id":"movies","Name":"电影","Type":"CollectionFolder"}]}',
                      200,
                    );
                  }
                  if (r.url.path.endsWith('/Latest')) {
                    return response(jsonEncode(data.take(8).toList()), 200);
                  }
                  if (r.url.path.endsWith('/Resume')) {
                    return response('{"Items":[]}', 200);
                  }
                  return response(
                    jsonEncode({
                      'Items': data,
                      'TotalRecordCount': data.length,
                    }),
                    200,
                  );
                }),
              );
              final repaint = GlobalKey();
              await tester.pumpWidget(
                RepaintBoundary(
                  key: repaint,
                  child: YingyuApp(
                    store: store,
                    api: api,
                    backendFactory: () => throw StateError('No native player'),
                  ),
                ),
              );
              await settleOffline(tester);
              await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
              await settleOffline(tester);
              final cards = !phone && display == LibraryDisplay.standard
                  ? find.byType(MediaCard)
                  : find.byType(LibraryPosterCard);
              final grid = tester.widget<SliverGrid>(
                find.byWidgetPredicate((widget) => widget is SliverGrid),
              );
              final columns =
                  (grid.gridDelegate
                          as SliverGridDelegateWithFixedCrossAxisCount)
                      .crossAxisCount;
              expect(
                columns,
                phone
                    ? 3
                    : display == LibraryDisplay.standard
                    ? size.value.width < 600
                          ? 1
                          : size.value.width < 840
                          ? 2
                          : 3
                    : size.value.width < 600
                    ? 3
                    : greaterThanOrEqualTo(3),
              );
              List<Rect> rowRects() => [
                for (var i = 0; i < columns; i++) tester.getRect(cards.at(i)),
              ];
              final before = rowRects();
              expect(
                before.first.left,
                closeTo(phone ? 16 : pageInset(size.value.width), .1),
              );
              expect(
                size.value.width - before.last.right,
                closeTo(phone ? 28 : before.first.left, .1),
              );
              await tester.tap(find.byKey(const Key('library-sort')));
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(const ValueKey('sort:DateCreated')));
              await settleOffline(tester);
              expect(
                rowRects(),
                before,
                reason: 'Removing the rail never changes card geometry',
              );
              await tester.tap(find.byKey(const Key('library-sort')));
              await tester.pumpAndSettle();
              await tester.tap(find.byKey(const ValueKey('sort:alphabet')));
              await settleOffline(tester);
              expect(rowRects(), before);
              final rail = find.byKey(const Key('alphabet-hit-area'));
              final railRect = tester.getRect(rail);
              final dock = tester.getRect(
                find.byKey(const Key('phone-navigation')),
              );
              final viewport = tester.widget<CustomScrollView>(
                find.byType(CustomScrollView),
              );
              viewport.controller!.jumpTo(1400);
              await settleOffline(tester);
              final backtop = tester.getRect(
                find.byKey(const Key('scroll-to-top')),
              );
              await tester.tap(find.byKey(const Key('library-search')));
              final keyboardHeight = size.value.height * .42;
              tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
              await tester.pump();
              expect(tester.getRect(rail), railRect);
              expect(
                tester.getRect(find.byKey(const Key('phone-navigation'))),
                dock,
              );
              expect(
                tester.getRect(find.byKey(const Key('scroll-to-top'))),
                backtop,
              );
              // The menu itself stays above the IME and can scroll internally.
              await tester.tap(find.byKey(const Key('library-sort')));
              await tester.pumpAndSettle();
              expect(
                tester
                    .getRect(find.byKey(const Key('browse-menu-panel')))
                    .bottom,
                lessThanOrEqualTo(size.value.height - keyboardHeight),
              );
              tester.view.resetViewInsets();
              await tester.pumpAndSettle();
              FocusManager.instance.primaryFocus?.unfocus();
              viewport.controller!.jumpTo(0);
              await settleOffline(tester);
              await savePreview(
                tester,
                repaint,
                'display-${size.key}-${mode.name}-${display.name}',
              );
              // Each main heading precedes the sole visible retry banner.
              for (final tab in [0, 1, 2, 3]) {
                await tester.tap(find.byKey(ValueKey('navigation-tab-$tab')));
                await settleOffline(tester);
                api.connection.finish(
                  api.connection.begin(),
                  ServerStatus.disconnected,
                  reason: '合成断开提示',
                );
                await tester.pump();
                final banner = find.byKey(
                  const Key('server-connection-warning'),
                );
                expect(banner, findsOneWidget);
                final title = find.text(['首页', '媒体库', '设置', '账户'][tab]).first;
                expect(
                  tester.getRect(banner).top,
                  greaterThan(tester.getRect(title).bottom),
                );
                expect(
                  find.byKey(const Key('retry-server-connection')),
                  findsOneWidget,
                );
              }
              await tester.pumpWidget(const SizedBox());
              preferences.dispose();
              api.close();
              store.dispose();
              expect(tester.takeException(), isNull);
            } finally {
              debugDisableShadows = oldShadows;
              posterCache = oldPoster;
              artworkCache = oldArtwork;
            }
          },
        );
      }
    }
  }

  testWidgets(
    'display preference is selectable in settings and survives restart',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1280);
      tester.view.display.size = const Size(800, 1280);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.display.resetSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      syntheticImagePaths();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(
        InterfacePreferences(prefs).libraryDisplay,
        LibraryDisplay.posters,
      );
      final store = AppStore(prefs);
      await store.saveSession(syntheticSession());
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            r.url.path.endsWith('/Users/synthetic-user')
                ? '{"Id":"synthetic-user"}'
                : r.url.path.endsWith('/Latest')
                ? '[]'
                : '{"Items":[]}',
            200,
          ),
        ),
      );
      await tester.pumpWidget(
        YingyuApp(
          store: store,
          api: api,
          backendFactory: () => throw StateError('No native player'),
        ),
      );
      await settleOffline(tester);
      for (final display in [LibraryDisplay.posters, LibraryDisplay.standard]) {
        await tester.tap(find.byKey(const ValueKey('navigation-tab-2')));
        await settleOffline(tester);
        await tester.ensureVisible(
          find.byKey(const Key('library-display-setting-arrow')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('library-display-setting-arrow')),
        );
        await settleOffline(tester);
        expect(
          tester.getRect(find.text('海报墙').last).top,
          lessThan(tester.getRect(find.text('图文列表').last).top),
        );
        await tester.tap(
          find.byKey(ValueKey('library-display-setting-choice-$display')),
        );
        await settleOffline(tester);
        expect(InterfacePreferences(prefs).libraryDisplay, display);
        await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
        await settleOffline(tester);
        expect(
          tester.widget<LibraryPage>(find.byType(LibraryPage)).display,
          display,
        );
      }
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    },
  );
}

Future<void> savePreview(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui-previews/$appVersion-$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}
