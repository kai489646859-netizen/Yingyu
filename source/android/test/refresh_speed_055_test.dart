import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show response, syntheticSession;

class CountingPreferences extends InMemorySharedPreferencesStore {
  CountingPreferences() : super.withData({});
  int writes = 0;
  Completer<void>? gate, entered;
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.endsWith(BrowseCache.storageKey)) {
      writes++;
      if (entered?.isCompleted == false) entered!.complete();
      await gate?.future;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final metrics = <String, dynamic>{};
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() {
    final file = File('build/refresh-speed-results.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(metrics)}\n',
    );
  });
  for (final hidden in [false, true]) {
    test(
      'refresh 2000 cached items reduces real work hidden=$hidden',
      () async {
        final platform = CountingPreferences();
        SharedPreferencesStorePlatform.instance = platform;
        final prefs = await SharedPreferences.getInstance(),
            store = AppStore(prefs);
        final items = List.generate(
          2000,
          (i) => MediaItem({
            'Id': 'm$i',
            'Name': '合成影片 $i',
            'Type': 'Movie',
            '_YingyuLibraryIdsV1': [i.isEven ? 'public' : 'hidden'],
          }),
        );
        var lookups = 0, catalogues = 0;
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/Views')) {
              return response(
                jsonEncode({
                  'Items': [
                    {'Id': 'public', 'Name': '动漫', 'Type': 'CollectionFolder'},
                    if (hidden)
                      {
                        'Id': 'hidden',
                        'Name': '电影',
                        'Type': 'CollectionFolder',
                      },
                  ],
                }),
                200,
              );
            }
            if (r.url.path.endsWith('/Resume')) {
              return response(
                jsonEncode({
                  'Items': [items.first.data],
                  'TotalRecordCount': 1,
                }),
                200,
              );
            }
            if (r.url.path.endsWith('/Latest')) {
              return response(
                jsonEncode(items.take(24).map((e) => e.data).toList()),
                200,
              );
            }
            final ids = r.url.queryParameters['Ids'];
            if (ids != null) {
              lookups++;
              final found = ids.split(',');
              return response(
                jsonEncode({
                  'Items': [
                    for (final id in found) {'Id': id},
                  ],
                  'TotalRecordCount': found.length,
                }),
                200,
              );
            }
            catalogues++;
            final parent = r.url.queryParameters['ParentId'];
            final values = hidden
                ? items
                      .where(
                        (i) => (i.data['_YingyuLibraryIdsV1'] as List).contains(
                          parent,
                        ),
                      )
                      .toList()
                : items;
            return response(
              jsonEncode({
                'Items': values.map((i) => i.data).toList(),
                'TotalRecordCount': values.length,
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        if (hidden) await store.homeOrder.saveHidden(api.session!, {'hidden'});
        final repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
          visibility: store.homeOrder,
        );
        final feed = HomeFeed(api, store, browse: repo, preloadSearch: true);
        addTearDown(() {
          feed.dispose();
          repo.dispose();
          store.dispose();
          api.close();
        });
        await repo.cache.put(
          repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
          CataloguePage(items, items.length),
          DateTime.now().subtract(const Duration(days: 1)),
        );
        // Complete the constructor's initial hidden-membership resolution
        // before measuring this separate user refresh.
        if (hidden) await repo.ensureVisibility();
        lookups = 0;
        catalogues = 0;
        platform.writes = 0;
        final watch = Stopwatch()..start();
        await feed.refresh(force: true, reconcile: true);
        watch.stop();
        metrics['refresh_hidden_$hidden'] = {
          'items': items.length,
          'lookup_requests': lookups,
          'catalogue_requests': catalogues,
          'cache_writes': platform.writes,
          'elapsed_ms': watch.elapsedMilliseconds,
        };
        expect(feed.error, isNull);
        expect(feed.loading, false);
        expect(feed.sections.first.items, isNotEmpty);
        expect(lookups, 0);
        expect(catalogues, hidden ? 2 : 1);
        expect(platform.writes, 1);
        if (hidden) {
          expect(store.homeOrder.visible(api.session!, items).length, 1000);
        }
      },
    );
  }
  test('refresh waits for the actual cache save before completing', () async {
    final platform = CountingPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    final prefs = await SharedPreferences.getInstance(),
        store = AppStore(prefs);
    final api = EmbyClient(
      client: MockClient(
        (r) async => response('{"Items":[],"TotalRecordCount":0}', 200),
      ),
    )..session = syntheticSession();
    final repo = BrowseRepository(
      api,
      BrowseCache(prefs),
      BrowsePreferences(prefs),
      spacing: Duration.zero,
    );
    final feed = HomeFeed(api, store, browse: repo);
    platform.gate = Completer<void>();
    platform.entered = Completer<void>();
    var complete = false;
    final task = feed.refresh(force: true).then((_) => complete = true);
    await platform.entered!.future;
    expect(complete, false);
    expect(feed.loading, true);
    platform.gate!.complete();
    await task;
    expect(feed.loading, false);
    expect(feed.error, isNull);
    feed.dispose();
    repo.dispose();
    store.dispose();
    api.close();
  });
  test(
    'cached visibility projection benchmark keeps exact membership',
    () async {
      final account = syntheticSession(),
          order = HomeOrder(await SharedPreferences.getInstance());
      final items = List.generate(
        5000,
        (i) => MediaItem({
          'Id': 'm$i',
          'Type': 'Movie',
          '_YingyuLibraryIdsV1': [i.isEven ? 'public' : 'hidden'],
        }),
      );
      await order.saveHidden(account, {'hidden'});
      order.resolveMembership(account, items, ['public', 'hidden']);
      final samples = <int>[];
      for (var n = 0; n < 5; n++) {
        final watch = Stopwatch()..start();
        final result = order.visible(account, items);
        watch.stop();
        expect(result.length, 2500);
        expect(result.every((i) => int.parse(i.id.substring(1)).isEven), true);
        samples.add(watch.elapsedMicroseconds);
      }
      samples.sort();
      metrics['cached_visibility'] = {
        'items': 5000,
        'median_us': samples[2],
        'samples_us': samples,
        'synthetic_host_only': true,
      };
      order.dispose();
    },
  );
}
