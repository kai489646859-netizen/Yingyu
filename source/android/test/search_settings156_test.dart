import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/ui/actor_search_results.dart';
import 'package:yingyu/ui/people.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

void main() {
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    for (final mediaType in ['', 'Series']) {
      testWidgets(
        'single character actor search is independent of ${mediaType.isEmpty ? 'empty' : 'series-only'} media results $size',
        (tester) async {
          setDisplay(tester, size);
          final pause = Object();
          PosterDemand.pause(pause, true);
          final queries = <String>[];
          final api = EmbyClient(
            client: MockClient((request) async {
              if (request.url.path.endsWith('/Persons')) {
                if (request.url.queryParameters['SearchTerm']
                    case final String term) {
                  queries.add(term);
                }
                return response(
                  jsonEncode({
                    'Items': [
                      {'Id': 'person-an', 'Name': '安迪', 'Type': 'Person'},
                    ],
                    'TotalRecordCount': 1,
                  }),
                  200,
                );
              }
              if (request.url.path.endsWith('/Views')) {
                return response(
                  '{"Items":[{"Id":"library","Name":"Library","Type":"CollectionFolder"}]}',
                  200,
                );
              }
              return response(
                jsonEncode({
                  'Items': [
                    if (mediaType.isNotEmpty)
                      {'Id': 'series-an', 'Name': '安家', 'Type': mediaType},
                  ],
                  'TotalRecordCount': mediaType.isEmpty ? 0 : 1,
                }),
                200,
              );
            }),
          )..session = syntheticSession();
          final store = AppStore(await SharedPreferences.getInstance());
          final browse = BrowseRepository(
            api,
            store.browseCache,
            BrowsePreferences(store.prefs),
            spacing: Duration.zero,
          );
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: LibraryPage(
                    api: api,
                    browse: size.width > 1000 ? browse : null,
                    searchMode: true,
                    onItem: (_) async {},
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          await tester.enterText(find.byKey(const Key('library-search')), '安');
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 450));
          await tester.pumpAndSettle();
          expect(queries, ['安']);
          expect(
            find.descendant(
              of: find.byType(ActorSearchResults),
              matching: find.text('安迪'),
            ),
            findsOneWidget,
          );
          expect(find.text('演员'), findsWidgets);
          expect(tester.takeException(), isNull);
          await captureOffline(
            tester,
            boundary,
            'search172-${size.width.toInt()}-${mediaType.isEmpty ? 'actor-only' : 'series-and-actor'}',
          );
          await tester.pumpWidget(const SizedBox());
          api.close();
          browse.dispose();
          store.log.dispose();
          store.dispose();
          PosterDemand.pause(pause, false);
        },
      );
    }
  }
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('ordinary search finds actors and opens their films $size', (
      tester,
    ) async {
      setDisplay(tester, size);
      final paused = Object();
      PosterDemand.pause(paused, true);
      final queries = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Persons')) {
            expect(r.url.queryParameters['Fields'], 'ProviderIds');
            if (r.url.queryParameters['SearchTerm'] case final String term) {
              queries.add(term);
            }
            return response(
              jsonEncode({
                'Items': [
                  {
                    'Id': 'person',
                    'Name': '张三',
                    'Type': 'Person',
                    'PrimaryImageTag': 'actor',
                  },
                ],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/Views')) {
            return response(
              '{"Items":[{"Id":"library","Name":"Library","Type":"CollectionFolder"}]}',
              200,
            );
          }
          return response(
            jsonEncode({
              'Items': [
                {'Id': 'movie', 'Type': 'Movie', 'Name': '张三的作品'},
              ],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final store = AppStore(await SharedPreferences.getInstance());
      final browse = BrowseRepository(
        api,
        store.browseCache,
        BrowsePreferences(store.prefs),
        spacing: Duration.zero,
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: LibraryPage(
                api: api,
                browse: size.width > 1000 ? browse : null,
                searchMode: true,
                onItem: (_) async {},
              ),
            ),
          ),
        ),
      );
      await settleOffline(tester);
      expect(find.text('演员'), findsNothing);
      await tester.enterText(find.byKey(const Key('library-search')), '张三');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(queries, ['张三', '张', '三']);
      expect(find.byKey(const Key('actor-search-results')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ActorSearchResults),
          matching: find.text('张三'),
        ),
        findsOneWidget,
      );
      await captureOffline(tester, boundary, 'search156-${size.width.toInt()}');
      await tester.tap(find.byKey(const ValueKey('person:person:张三')));
      await tester.pumpAndSettle();
      expect(find.byType(PeoplePage), findsOneWidget);
      expect(find.text('张三的影片'), findsOneWidget);
      expect(queries, ['张三', '张', '三']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.close();
      browse.dispose();
      store.log.dispose();
      store.dispose();
      PosterDemand.pause(paused, false);
    });
  }
  testWidgets(
    'actor search discards stale queries and pauses optional requests',
    (tester) async {
      final old = Completer<void>();
      final calls = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          final term = r.url.queryParameters['SearchTerm'];
          if (term == null) {
            return response(
              jsonEncode({
                'Items': [
                  for (final name in ['旧甲', '新乙', '等待丙'])
                    {'Id': name, 'Name': name, 'Type': 'Person'},
                ],
                'TotalRecordCount': 3,
              }),
              200,
            );
          }
          calls.add(term);
          if (term == '旧甲') await old.future;
          return response(
            jsonEncode({
              'Items': [
                {'Id': term, 'Name': term, 'Type': 'Person'},
              ],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      var term = '旧甲';
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              change = setState;
              return ActorSearchResults(
                api: api,
                query: term,
                active: true,
                onItem: (_) async {},
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 450));
      change(() => term = '新乙');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      old.complete();
      await tester.pumpAndSettle();
      expect(find.text('新乙'), findsOneWidget);
      expect(find.text('旧甲'), findsNothing);
      final pause = Object();
      api.backgroundWork.pause(pause, true);
      change(() => term = '等待丙');
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(calls.where((q) => q.length > 1), ['旧甲', '新乙']);
      expect(calls.any((q) => q.contains('等待')), false);
      api.backgroundWork.pause(pause, false);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(calls.where((q) => q.length > 1), ['旧甲', '新乙', '等待丙']);
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'limits and cleanups are contiguous; six readable themes $size',
      (tester) async {
        setDisplay(tester, size);
        final prefs = await SharedPreferences.getInstance();
        final store = AppStore(prefs);
        final api = EmbyClient(
          client: MockClient((_) async => response('{"Items":[]}', 200)),
        )..session = syntheticSession();
        final browse = BrowseRepository(
          api,
          store.browseCache,
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: SettingsPage(store: store, browse: browse),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('缓存与加载'),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        final groups = tester.widgetList<SettingsGroup>(
          find.byType(SettingsGroup),
        );
        final cache = groups.singleWhere((g) => g.title == '缓存与加载');
        expect(
          cache.children
              .take(4)
              .whereType<SettingsChoice<int>>()
              .map((w) => w.id),
          [
            'actor-cache-limit',
            'cache-limit',
            'landscape-cache-limit',
            'playback-cache-limit',
          ],
        );
        final cleanups = cache.children
            .whereType<SettingsAction>()
            .map((w) => w.id)
            .toList();
        expect(cleanups, [
          'clear-actor-cache',
          'clear-landscape-cache',
          'clear-poster-cache',
          'clear-artwork-cache',
          'clear-browse-cache',
          'clear-playback-cache',
        ]);
        final first = cache.children.indexWhere((w) => w is SettingsAction);
        expect(
          cache.children.skip(first).take(6).every((w) => w is SettingsAction),
          true,
        );
        expect(
          groups
              .where((g) => g.title == '播放')
              .expand((g) => g.children)
              .whereType<SettingsAction>()
              .where((w) => w.id == 'clear-playback-cache'),
          isEmpty,
        );
        for (final accent in AppAccent.available) {
          await store.setAccent(accent);
          expect(store.accent, accent);
          for (final brightness in Brightness.values) {
            final scheme = appTheme(
              brightness,
              accentChoice: accent,
            ).colorScheme;
            final l1 = scheme.primary.computeLuminance(),
                l2 = scheme.onPrimary.computeLuminance();
            expect(
              (l1 > l2 ? (l1 + .05) / (l2 + .05) : (l2 + .05) / (l1 + .05)),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        browse.dispose();
        api.close();
        store.log.dispose();
        store.dispose();
      },
    );
  }
}
