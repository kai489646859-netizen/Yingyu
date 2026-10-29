import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/catalog_filters.dart';
import 'package:yingyu/core/catalog_sort.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/home_visibility.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, syntheticSession;
import 'cache_settings_test.dart' show fonts;
import 'offline_settle.dart';
import 'offline_capture.dart';

final rows = prepareCatalog([
  MediaItem({
    'Id': 'movie',
    'Name': '星际电影',
    'Type': 'Movie',
    'ProductionYear': 2024,
    'PremiereDate': '2024-06-01T00:00:00Z',
    'CommunityRating': 8.2,
    'Genres': ['科幻'],
    'UserData': {'IsFavorite': true, 'Played': false},
  }),
  MediaItem({
    'Id': 'series',
    'Name': '星际剧集',
    'Type': 'Series',
    'ProductionYear': 2020,
    'CommunityRating': 7.1,
    'Genres': ['剧情'],
    'UserData': {'IsFavorite': false, 'Played': true},
  }),
  MediaItem({'Id': 'unknown', 'Name': '星际未知', 'Type': 'Video'}),
  MediaItem({
    'Id': 'other',
    'Name': '旧日电影',
    'Type': 'Movie',
    'ProductionYear': 1999,
    'Genres': ['科幻'],
    'UserData': {'IsFavorite': false, 'Played': false},
  }),
]);

void main() {
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    SharedPreferences.setMockInitialValues({});
    syntheticImagePaths();
  });
  test('combined exact metadata filters, pinyin search and unknown data', () {
    List<String> select(CatalogFilters f, {String q = '', bool? played}) =>
        selectFilteredCatalog((
          rows,
          q,
          played,
          f,
        )).items.map((i) => i.id).toList();
    expect(
      select(
        const CatalogFilters(kind: CatalogKind.movie, year: 2024),
        q: 'XJ',
        played: false,
      ),
      ['movie'],
    );
    expect(select(const CatalogFilters(kind: CatalogKind.favorite)), ['movie']);
    expect(
      select(const CatalogFilters(kind: CatalogKind.series, decade: 2020)),
      ['series'],
    );
    expect(select(const CatalogFilters(decade: 1990)), ['other']);
    expect(select(const CatalogFilters(), played: false), ['other', 'movie']);
    expect(select(const CatalogFilters(year: 2023)), isEmpty);
    expect(
      select(const CatalogFilters(kind: CatalogKind.movie), q: '剧集'),
      isEmpty,
    );
    expect(select(const CatalogFilters()), contains('unknown'));
  });
  test(
    'release ordering compares real dates and keeps missing values last',
    () {
      final values = [
        MediaItem({
          'Id': 'early',
          'Name': 'early',
          'ProductionYear': 2024,
          'PremiereDate': '2024-01-02',
        }),
        rows.firstWhere((i) => i.id == 'movie'),
        rows.firstWhere((i) => i.id == 'unknown'),
      ];
      expect(orderCatalog((values, 'PremiereDate', true)).map((i) => i.id), [
        'movie',
        'early',
        'unknown',
      ]);
      expect(orderCatalog((values, 'PremiereDate', false)).map((i) => i.id), [
        'early',
        'movie',
        'unknown',
      ]);
    },
  );
  for (final malformed in [
    'missing-count',
    'duplicate',
    'short',
    'changed-total',
  ]) {
    test(
      'hidden membership is withheld on incomplete catalogue $malformed',
      () async {
        final prefs = await SharedPreferences.getInstance(),
            order = HomeOrder(await SharedPreferences.getInstance());
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/Views')) {
              return response(
                '{"Items":[{"Id":"public"},{"Id":"hidden"}]}',
                200,
              );
            }
            final start = int.parse(r.url.queryParameters['StartIndex'] ?? '0');
            final data = <String, dynamic>{
              'Items': start == 0 ? [rows[0].data] : [],
              'TotalRecordCount': 1,
            };
            if (malformed == 'missing-count') data.remove('TotalRecordCount');
            if (malformed == 'duplicate') {
              data['Items'] = [rows[0].data, rows[0].data];
              data['TotalRecordCount'] = 2;
            }
            if (malformed == 'short') data['TotalRecordCount'] = 2;
            if (malformed == 'changed-total') {
              data['TotalRecordCount'] = start == 0 ? 2 : 1;
            }
            return response(jsonEncode(data), 200);
          }),
        )..session = syntheticSession();
        await order.saveHidden(api.session!, {'hidden'});
        final repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
          visibility: order,
        );
        await repo.ensureVisibility(force: true);
        expect(order.ready(api.session!), false);
        expect(order.visible(api.session!, rows), isEmpty);
        expect(order.visibilityError(api.session!), isNotNull);
        repo.dispose();
        order.dispose();
        api.close();
      },
    );
  }
  for (final width in [412.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'search combines controls, reuses cache, keeps keyboard dismissed $width $brightness',
        (tester) async {
          tester.view.physicalSize = Size(width, width == 412 ? 915 : 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final prefs = await SharedPreferences.getInstance(),
              order = HomeOrder(await SharedPreferences.getInstance());
          var requests = 0, opened = 0;
          final api = EmbyClient(
            client: MockClient((r) async {
              if (r.url.path.endsWith('/Persons')) {
                return response('{"Items":[],"TotalRecordCount":0}', 200);
              }
              requests++;
              return response('{"Items":[],"TotalRecordCount":0}', 200);
            }),
          )..session = syntheticSession();
          final repo = BrowseRepository(
            api,
            BrowseCache(prefs),
            BrowsePreferences(prefs),
            spacing: Duration.zero,
          );
          final tagged = [
            for (final item in rows)
              MediaItem({
                ...item.data,
                '_YingyuLibraryIdsV1': [
                  item.type == 'Movie' ? 'public' : 'anime',
                ],
              }),
          ];
          await repo.cache.put(
            repo.key('views'),
            ItemPage([
              MediaItem({
                'Id': 'public',
                'Name': '电影',
                'Type': 'CollectionFolder',
              }),
              MediaItem({
                'Id': 'anime',
                'Name': '动漫',
                'Type': 'CollectionFolder',
              }),
            ], 2),
            DateTime.now(),
          );
          await repo.cache.put(
            repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
            CataloguePage(
              tagged,
              tagged.length,
              scopes: ['public', 'anime'],
              membershipVerified: true,
            ),
            DateTime.now(),
          );
          final boundary = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: HomeVisibilityScope(
                  order: order,
                  child: Scaffold(
                    resizeToAvoidBottomInset: false,
                    body: SafeArea(
                      child: LibraryPage(
                        api: api,
                        browse: repo,
                        searchMode: true,
                        onItem: (_) async {
                          opened++;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          expect(
            requests,
            0,
            reason: 'fresh shared directory is enough to enter and search',
          );
          expect(
            find.byKey(const Key('library-loading-indicator')),
            findsNothing,
          );
          final field = find.byKey(const Key('library-search'));
          await tester.enterText(field, '星际');
          await tester.pump(const Duration(milliseconds: 220));
          expect(find.text('动漫'), findsOneWidget);
          expect(find.text('电视剧'), findsNothing);
          expect(
            tester.getTopLeft(find.byKey(const Key('filter-kind-all'))).dx,
            tester.getTopLeft(find.byKey(const Key('filter-sort-alphabet'))).dx,
          );
          await tester.tap(find.byKey(const Key('filter-kind-library:anime')));
          await tester.pumpAndSettle();
          expect(find.text('星际剧集'), findsOneWidget);
          expect(find.text('星际电影'), findsNothing);
          await tester.tap(find.byKey(const Key('filter-kind-library:public')));
          await tester.pumpAndSettle();
          expect(find.text('星际电影'), findsOneWidget);
          expect(find.text('星际剧集'), findsNothing);
          await tester.tap(find.byKey(const Key('filter-year-year:2024')));
          await tester.pumpAndSettle();
          expect(find.text('星际电影'), findsOneWidget);
          expect(
            tester.widget<CupertinoSearchTextField>(field).focusNode!.hasFocus,
            false,
          );
          expect(find.byKey(const Key('library-picker')), findsNothing);
          await tester.tap(find.byKey(const Key('library-sort')));
          await tester.pumpAndSettle();
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(
            tester.widget<CupertinoSearchTextField>(field).focusNode!.hasFocus,
            false,
          );
          await tester.tap(field);
          await tester.pumpAndSettle();
          expect(
            tester.widget<CupertinoSearchTextField>(field).focusNode!.hasFocus,
            true,
          );
          await tester.tapAt(
            Offset(width * .5, (width == 412 ? 915 : 800) - 30),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<CupertinoSearchTextField>(field).focusNode!.hasFocus,
            false,
          );
          await captureOffline(
            tester,
            boundary,
            'search-filters-${width.toInt()}-${brightness.name}',
          );
          await order.saveHidden(api.session!, {'public'});
          order.resolveMembership(api.session!, tagged, ['public', 'anime']);
          await tester.pumpAndSettle();
          expect(find.text('星际电影'), findsNothing);
          expect(
            find.byKey(const Key('filter-kind-library:public')),
            findsNothing,
          );
          await tester.tap(field);
          await tester.enterText(field, '星际电影');
          await tester.pump(const Duration(milliseconds: 250));
          expect(
            find.text('星际电影').evaluate().length,
            1,
            reason: 'only the typed query remains; no hidden result',
          );
          await order.saveHidden(api.session!, {});
          await tester.pumpAndSettle();
          expect(find.text('星际电影').evaluate().length, 2);
          expect(requests, 0);
          expect(opened, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          repo.dispose();
          order.dispose();
          api.close();
        },
      );
    }
  }
}
