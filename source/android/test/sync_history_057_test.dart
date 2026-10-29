import 'dart:convert';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/image_references.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'core_test.dart' show response, syntheticSession;

MediaItem movie(String id, {String type = 'Movie', String? tmdb}) => MediaItem({
  'Id': id,
  'Name': id,
  'Type': type,
  'ImageTags': {'Primary': 'tag'},
  if (tmdb != null) 'ProviderIds': {'Tmdb': tmdb},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  for (final count in [1, 228]) {
    test(
      'complete directory removes $count stale IDs with one normal request and zero probes',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final order = HomeOrder(prefs), refs = ImageReferences();
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((r) async {
            calls++;
            expect(r.url.queryParameters['Ids'], isNull);
            expect(r.url.path.endsWith('/Items'), isTrue);
            return response(
              jsonEncode({
                'Items': [movie('new').data],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        final repo = BrowseRepository(
          api,
          BrowseCache(prefs, images: refs),
          BrowsePreferences(prefs),
          visibility: order,
          spacing: Duration.zero,
        );
        final old = List.generate(count, (i) => movie('old$i'));
        await repo.cache.put(
          repo.key('stale'),
          ItemPage(old, count),
          DateTime.now(),
        );
        final cleaned = <String>{};
        refs.deleteFiles = (keys, allowed) async =>
            cleaned.addAll(keys.where(allowed));
        final page = await repo.catalogue(force: true);
        expect(page.items.single.id, 'new');
        expect(order.removals.ids(api.session!), old.map((e) => e.id).toSet());
        expect(repo.peek('stale')!.items, isEmpty);
        expect(await repo.finishLocalSync(), old.map((e) => e.id).toSet());
        expect(calls, 1);
        expect(cleaned, isNotEmpty);
        repo.dispose();
        api.close();
        order.dispose();
      },
    );
  }

  test(
    'same count replacement compares IDs; another account and surviving series episodes remain',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final order = HomeOrder(prefs);
      final api = EmbyClient(
        client: MockClient(
          (_) async => response(
            jsonEncode({
              'Items': [
                movie('series', type: 'Series').data,
                movie('new').data,
              ],
              'TotalRecordCount': 2,
            }),
            200,
          ),
        ),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      await repo.cache.put(
        repo.key('old'),
        ItemPage([movie('series', type: 'Series'), movie('gone')], 2),
        DateTime.now(),
      );
      await repo.cache.put(
        repo.key('episode'),
        ItemPage([
          MediaItem({'Id': 'episode', 'Type': 'Episode', 'SeriesId': 'series'}),
        ], 1),
        DateTime.now(),
      );
      const other = '["https://other.invalid","user","old"]';
      await repo.cache.put(other, ItemPage([movie('gone')], 1), DateTime.now());
      await repo.catalogue(force: true);
      expect(order.removals.ids(api.session!), {'gone'});
      expect(repo.peek('episode')!.items, hasLength(1));
      expect(repo.cache.records[other]!.items, hasLength(1));
      repo.dispose();
      api.close();
    },
  );

  for (final invalid in [
    'missing-count',
    'duplicate',
    'changing-total',
    'failure',
  ]) {
    test('$invalid directory never authorizes deletion', () async {
      final prefs = await SharedPreferences.getInstance();
      final order = HomeOrder(prefs);
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((_) async {
          calls++;
          if (invalid == 'failure') return response('{}', 503);
          return response(
            jsonEncode({
              'Items': [
                movie('live').data,
                if (invalid == 'duplicate') movie('live').data,
              ],
              if (invalid != 'missing-count')
                'TotalRecordCount': invalid == 'changing-total' && calls > 1
                    ? 3
                    : 2,
            }),
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
      await repo.cache.put(
        repo.key('old'),
        ItemPage([movie('gone')], 1),
        DateTime.now(),
      );
      await expectLater(
        repo.catalogue(force: true),
        throwsA(isA<AppFailure>()),
      );
      expect(order.removals.ids(api.session!), isEmpty);
      expect(repo.peek('old')!.items, hasLength(1));
      repo.dispose();
      api.close();
    });
  }

  test('latest and cached catalogue omissions never prove deletion', () async {
    final prefs = await SharedPreferences.getInstance();
    final order = HomeOrder(prefs);
    var calls = 0;
    final api = EmbyClient(
      client: MockClient((_) async {
        calls++;
        return response('[]', 200);
      }),
    )..session = syntheticSession();
    final repo = BrowseRepository(
      api,
      BrowseCache(prefs),
      BrowsePreferences(prefs),
      visibility: order,
      spacing: Duration.zero,
    );
    await repo.cache.put(
      repo.key('old'),
      ItemPage([movie('gone')], 1),
      DateTime.now(),
    );
    await repo.cache.put(
      repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
      ItemPage([], 0),
      DateTime.now(),
    );
    await repo.latest('lib', force: true);
    await repo.catalogue();
    expect(await repo.finishLocalSync(), isEmpty);
    expect(calls, 1);
    expect(order.removals.ids(api.session!), isEmpty);
    repo.dispose();
    api.close();
  });

  test(
    'fresh complete season removes only that season missing episodes',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final order = HomeOrder(prefs);
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((_) async {
          calls++;
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      await repo.cache.put(
        repo.key('episodes'),
        ItemPage([
          for (final season in ['s1', 's2'])
            MediaItem({
              'Id': season,
              'Type': 'Episode',
              'SeriesId': 'show',
              'SeasonId': season,
            }),
        ], 2),
        DateTime.now(),
      );
      await repo.episodeCatalogue('show', 's1', force: true);
      expect(order.removals.ids(api.session!), {'s1'});
      expect(calls, 1);
      repo.dispose();
      api.close();
    },
  );

  test(
    'manual resource snapshot removes one episode while keeping its series and shares one request',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          order = HomeOrder(await SharedPreferences.getInstance());
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          expect(
            r.url.queryParameters['IncludeItemTypes'],
            contains('Episode'),
          );
          return response(
            jsonEncode({
              'Items': [
                movie('series', type: 'Series').data,
                {'Id': 'live-episode', 'Type': 'Episode', 'SeriesId': 'series'},
              ],
              'TotalRecordCount': 2,
            }),
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
      await repo.cache.put(
        repo.key('old'),
        ItemPage([
          movie('series', type: 'Series'),
          MediaItem({
            'Id': 'gone-episode',
            'Type': 'Episode',
            'SeriesId': 'series',
          }),
        ], 2),
        DateTime.now(),
      );
      final page = await repo.catalogue(force: true, resourceSnapshot: true);
      expect(page.items.map((e) => e.id), ['series']);
      expect(order.removals.ids(api.session!), {'gone-episode'});
      expect(calls, 1);
      expect(repo.peekSharedCatalogue(null)!.items.map((e) => e.id), [
        'series',
      ]);
      repo.dispose();
      api.close();
    },
  );

  test(
    'image refs survive restart, share TMDB across accounts and defer pinned images',
    () async {
      final dir = await Directory.systemTemp.createTemp('yingyu-refs-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/refs.jsonl');
      final a = syntheticSession(),
          b = syntheticSession('https://other.invalid');
      final refs = ImageReferences(file: file);
      refs.observe(a, [movie('a', tmdb: '123')]);
      refs.observe(b, [movie('b', tmdb: '123')]);
      await refs.flush();
      final reopened = ImageReferences(file: file);
      await reopened.load();
      const shared = 'yingyu-image:tmdb:v1:movie:123:poster:360:85';
      final hash = ImageReferences.digest(shared);
      final cleaned = <String>{};
      reopened.deleteFiles = (keys, allowed) async =>
          cleaned.addAll(keys.where(allowed));
      await reopened.remove(a, {'a'});
      expect(cleaned, isNot(contains(hash)));
      reopened.pin(shared);
      await reopened.remove(b, {'b'});
      expect(cleaned, isNot(contains(hash)));
      reopened.unpin(shared);
      await reopened.sweep();
      expect(cleaned, contains(hash));
      expect(await file.readAsString(), isNot(contains(a.token)));
    },
  );

  test(
    'hidden is not deletion and corrupted image ownership fails closed',
    () async {
      final refs = ImageReferences();
      refs.observe(syntheticSession(), [movie('hidden', tmdb: '5')]);
      final removed = <String>{};
      refs.deleteFiles = (keys, allowed) async =>
          removed.addAll(keys.where(allowed));
      await refs.remove(syntheticSession(), {'different'});
      expect(removed, isEmpty);
      refs.healthy = false;
      await refs.remove(syntheticSession(), {'hidden'});
      expect(removed, isEmpty);
    },
  );

  test(
    'visibility edits keep known background rows and unknown IDs fail closed',
    () async {
      final order = HomeOrder(await SharedPreferences.getInstance()),
          a = syntheticSession();
      final public = MediaItem({
            ...movie('public').data,
            '_YingyuLibraryIdsV1': ['p'],
          }),
          hidden = MediaItem({
            ...movie('secret').data,
            '_YingyuLibraryIdsV1': ['h'],
          });
      order.resolveMembership(a, [public, hidden], ['p', 'h']);
      order.previewHidden(a, {'h'});
      order.beginResolution(a);
      expect(
        order.visible(a, [public, hidden, movie('unknown')]).map((e) => e.id),
        ['public'],
      );
      order.failResolution(a, 'offline');
      expect(order.visible(a, [public, hidden]).single.id, 'public');
      order.previewHidden(a, {});
      expect(order.visible(a, [public, hidden]), hasLength(2));
      order.dispose();
    },
  );

  test(
    'queued old visibility write cannot replace the newer preview',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final order = HomeOrder(prefs), account = syntheticSession();
      final older = order.previewHidden(account, {'first'});
      final newer = order.previewHidden(account, {'second'});
      await order.saveHidden(account, {'first'}, previewRevision: older);
      expect(order.hidden(account), {'second'});
      await order.saveHidden(account, {'second'}, previewRevision: newer);
      expect(HomeOrder(prefs).hidden(account), {'second'});
      order.dispose();
    },
  );

  testWidgets(
    'leaving library clears transient query without a new server request',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((_) async {
          calls++;
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      await repo.cache.put(repo.key('views'), ItemPage([], 0), DateTime.now());
      await repo.cache.put(
        repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
        ItemPage(prepareCatalog([movie('alpha'), movie('beta')]), 2),
        DateTime.now(),
      );
      var active = true;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return LibraryPage(
                  api: api,
                  browse: repo,
                  onItem: (_) async {},
                  active: active,
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(CupertinoSearchTextField), 'alpha');
      await tester.pump(const Duration(milliseconds: 200));
      update(() => active = false);
      await tester.pump();
      expect(
        tester
            .widget<CupertinoSearchTextField>(
              find.byType(CupertinoSearchTextField),
            )
            .controller!
            .text,
        '',
      );
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
    },
  );
}
