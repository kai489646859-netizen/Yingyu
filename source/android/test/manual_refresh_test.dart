import 'package:yingyu/ui/release_refresh.dart';
import 'dart:async';
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
import 'package:yingyu/ui/browse_page.dart';
import 'core_test.dart' show response, syntheticSession;
import 'offline_settle.dart';

class RefreshFixture {
  RefreshFixture(SharedPreferences prefs) {
    api = EmbyClient(
      client: MockClient((request) async {
        final path = request.url.path;
        final parent = request.url.queryParameters['ParentId'];
        if (path.endsWith('/Views')) {
          views++;
          await viewGate?.future;
          return response(
            jsonEncode({
              'Items': [
                for (final id in ['a', 'b'])
                  {'Id': id, 'Name': 'Library $id', 'Type': 'CollectionFolder'},
              ],
            }),
            200,
          );
        }
        if (path.endsWith('/Resume')) {
          resumes++;
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }
        if (path.endsWith('/Latest')) {
          latest.add(parent!);
          return response(jsonEncode([item(parent)]), 200);
        }
        if (path.endsWith('/Items')) {
          scopes.add(parent);
          if (failCatalogue) {
            return response('{"Message":"synthetic outage"}', 500);
          }
          final rows = [
            for (final id in parent == null ? ['a', 'b'] : [parent]) item(id),
          ];
          return response(
            jsonEncode({'Items': rows, 'TotalRecordCount': rows.length}),
            200,
          );
        }
        return response('', 404);
      }),
    )..session = syntheticSession();
    store = AppStore(prefs);
    repo = BrowseRepository(
      api,
      store.browseCache,
      BrowsePreferences(prefs),
      spacing: Duration.zero,
    );
    feed = HomeFeed(api, store, browse: repo);
    repo.onRemoved = feed.acceptRemovals;
  }
  late final EmbyClient api;
  late final AppStore store;
  late final BrowseRepository repo;
  late final HomeFeed feed;
  Completer<void>? viewGate;
  int views = 0, resumes = 0, version = 1;
  bool failCatalogue = false;
  final latest = <String>[];
  final scopes = <String?>[];
  Map<String, Object> item(String id) => {
    'Id': 'movie-$id',
    'Name': 'Movie $id v$version',
    'Type': 'Movie',
  };
  void dispose() {
    feed.dispose();
    repo.dispose();
    api.close();
    store.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  test(
    'manual refresh queued during an automatic read performs one forced full pass',
    () async {
      final f = RefreshFixture(await SharedPreferences.getInstance());
      addTearDown(f.dispose);
      f.viewGate = Completer<void>();
      final automatic = f.feed.refresh();
      while (f.views == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      final one = f.feed.refreshAll();
      final two = f.feed.refreshAll();
      f.viewGate!.complete();
      f.viewGate = null;
      await Future.wait([automatic, one, two]);
      expect(f.views, 2, reason: 'one automatic and exactly one forced read');
      expect(f.resumes, 2);
      expect(f.latest.where((e) => e == 'a'), hasLength(2));
      expect(f.latest.where((e) => e == 'b'), hasLength(2));
      expect(f.scopes, containsAll(['a', 'b']));
      expect(f.feed.error, isNull);
    },
  );

  test(
    'a failed full refresh reports failure and retains known items',
    () async {
      final f = RefreshFixture(await SharedPreferences.getInstance());
      addTearDown(f.dispose);
      await f.feed.refreshAll();
      f.failCatalogue = true;
      await expectLater(f.feed.refreshAll(), throwsA(isA<AppFailure>()));
      expect(f.feed.sections, hasLength(2));
      expect(f.feed.sections.every((s) => s.items.isNotEmpty), true);
      expect(f.repo.peekCatalogue(null, 'alphabet')!.items, hasLength(2));
    },
  );

  testWidgets(
    'pulling a selected library updates all libraries and the home feed once',
    (tester) async {
      final f = RefreshFixture(await SharedPreferences.getInstance());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(
              api: f.api,
              browse: f.repo,
              parent: MediaItem({
                'Id': 'a',
                'Name': 'Library a',
                'Type': 'CollectionFolder',
              }),
              onRefreshAll: f.feed.refreshAll,
              onItem: (_) async {},
            ),
          ),
        ),
      );
      await settleOffline(tester);
      final views = f.views, resumes = f.resumes;
      f.scopes.clear();
      f.latest.clear();
      f.version = 2;
      final pull = tester.widget<ReleaseRefreshScrollView>(
        find.byType(ReleaseRefreshScrollView, skipOffstage: false),
      );
      final one = pull.onRefresh();
      final two = pull.onRefresh();
      var done = false;
      unawaited(Future.wait([one, two]).then((_) => done = true));
      for (var i = 0; i < 100 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        done,
        true,
        reason: 'the full refresh must finish, including catalogue isolates',
      );
      await settleOffline(tester);
      expect(f.views, views + 1);
      expect(f.resumes, resumes + 1);
      expect(f.scopes, [
        'a',
        'b',
      ], reason: 'one full snapshot; the current view reuses it');
      expect(f.latest, containsAll(['a', 'b']));
      expect(
        f.feed.sections.every((s) => s.items.single.title.endsWith('v2')),
        true,
      );
      expect(find.text('Movie a v2'), findsOneWidget);
      expect(find.text('Movie b v2'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      f.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'homepage refresh synchronizes a tab entered while it is pending',
    (tester) async {
      final f = RefreshFixture(await SharedPreferences.getInstance());
      var active = true;
      late StateSetter changePage;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                changePage = setState;
                return LibraryPage(
                  api: f.api,
                  browse: f.repo,
                  active: active,
                  refreshFeed: f.feed,
                  onRefreshAll: f.feed.refreshAll,
                  parent: MediaItem({
                    'Id': 'a',
                    'Name': 'Library a',
                    'Type': 'CollectionFolder',
                  }),
                  onItem: (_) async {},
                );
              },
            ),
          ),
        ),
      );
      await settleOffline(tester);
      expect(find.text('Movie a v1'), findsOneWidget);
      changePage(() => active = false);
      await tester.pump();
      f.version = 2;
      f.viewGate = Completer<void>();
      final job = f.feed.refresh(force: true);
      await tester.pump();
      changePage(() => active = true);
      await tester.pump();
      expect(find.byKey(const Key('library-loading-indicator')), findsOneWidget);
      expect(find.text('正在刷新'), findsNothing);
      f.viewGate!.complete();
      f.viewGate = null;
      var completed = false;
      unawaited(job.then((_) => completed = true));
      for (var n = 0; n < 150 && !completed; n++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(completed, true);
      await settleOffline(tester);
      expect(find.text('Movie a v2'), findsOneWidget);
      expect(find.text('正在刷新'), findsNothing);
      expect(
        f.scopes.where((scope) => scope == 'b'),
        isEmpty,
        reason:
            'homepage refresh and current page must not scan the hidden library',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      f.dispose();
    },
  );
}
