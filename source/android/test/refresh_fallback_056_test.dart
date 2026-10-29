import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'core_test.dart' show response, syntheticSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final metrics = <String, Object>{};
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDownAll(() {
    final file = File('build/refresh-fallback-results.json');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(metrics)}\n',
    );
  });
  test(
    'bulk omission recovers 228 real IDs without 228 detail reads',
    () async {
      var calls = 0, details = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          calls++;
          final params = request.url.queryParameters;
          if (request.url.path.endsWith('/emby/Items')) {
            expect(params['UserId'], syntheticSession().userId);
            expect(params['Recursive'], isNull);
            final ids = params['Ids']!.split(',');
            return response(
              jsonEncode({
                'Items': [
                  for (final id in ids) {'Id': id},
                ],
                'TotalRecordCount': ids.length,
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/Items')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          details++;
          return response(
            jsonEncode({'Id': request.url.pathSegments.last}),
            200,
          );
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(await SharedPreferences.getInstance()),
        BrowsePreferences(await SharedPreferences.getInstance()),
        spacing: Duration.zero,
      );
      addTearDown(() {
        repo.dispose();
        api.close();
      });
      final entries = List.generate(
        228,
        (i) => MediaItem({'Id': 'id$i', 'Type': 'Episode'}),
      );
      await repo.cache.put(
        repo.key('cached-list'),
        ItemPage(entries, entries.length),
        DateTime.now(),
      );
      final watch = Stopwatch()..start();
      final missing = await repo.reconcileCachedItems();
      metrics['bulk_omission'] = {
        'cached_items': entries.length,
        'requests': calls,
        'detail_requests': details,
        'elapsed_us': watch.elapsedMicroseconds,
      };
      expect(missing, isEmpty);
      expect(repo.peek('cached-list')!.items, hasLength(228));
      expect(calls, 2);
      expect(details, 0);
    },
  );
  test(
    'small omission confirms deletion serially with request spacing',
    () async {
      var active = 0, peak = 0;
      final starts = <DateTime>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          starts.add(DateTime.now());
          if (r.url.path.endsWith('/emby/Items')) return response('{}', 404);
          if (r.url.path.endsWith('/Items')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 4));
          active--;
          final id = r.url.pathSegments.last;
          return id == 'gone'
              ? response('{}', 410)
              : response(jsonEncode({'Id': id}), 200);
        }),
      )..session = syntheticSession();
      final prefs = await SharedPreferences.getInstance();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: const Duration(milliseconds: 35),
      );
      addTearDown(() {
        repo.dispose();
        api.close();
      });
      final missing = await repo.reconcileCachedItems(
        extraIds: ['gone', ...List.generate(3, (i) => 'id$i')],
      );
      metrics['single_fallback'] = {'peak_active': peak};
      expect(missing, {'gone'});
      expect(peak, 1);
      for (var i = 1; i < starts.length; i++) {
        expect(
          starts[i].difference(starts[i - 1]).inMilliseconds,
          greaterThanOrEqualTo(30),
        );
      }
    },
  );
  test('invalid compatible batch cannot evict any cached item', () async {
    final api = EmbyClient(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/emby/Items')) {
          return response(
            '{"Items":[{"Id":"unrequested"}],"TotalRecordCount":1}',
            200,
          );
        }
        return response('{"Items":[],"TotalRecordCount":0}', 200);
      }),
    )..session = syntheticSession();
    final prefs = await SharedPreferences.getInstance();
    final repo = BrowseRepository(
      api,
      BrowseCache(prefs),
      BrowsePreferences(prefs),
      spacing: Duration.zero,
    );
    addTearDown(() {
      repo.dispose();
      api.close();
    });
    final entries = List.generate(12, (i) => MediaItem({'Id': 'id$i'}));
    await repo.cache.put(
      repo.key('saved'),
      ItemPage(entries, entries.length),
      DateTime.now(),
    );
    await expectLater(repo.reconcileCachedItems(), throwsA(isA<AppFailure>()));
    expect(repo.peek('saved')!.items, hasLength(12));
  });
  test(
    'single read error stops admission and preserves the whole snapshot',
    () async {
      var singles = 0;
      final gate = Completer<void>();
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/emby/Items')) return response('{}', 405);
          if (r.url.path.endsWith('/Items')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          final n = ++singles;
          if (n == 1) {
            await Future<void>.delayed(const Duration(milliseconds: 2));
            gate.complete();
            return response('{}', 429);
          }
          await gate.future;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          return response('{}', 404);
        }),
      )..session = syntheticSession();
      final prefs = await SharedPreferences.getInstance();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      addTearDown(() {
        repo.dispose();
        api.close();
      });
      final entries = List.generate(4, (i) => MediaItem({'Id': 'id$i'}));
      await repo.cache.put(
        repo.key('saved'),
        ItemPage(entries, entries.length),
        DateTime.now(),
      );
      await expectLater(
        repo.reconcileCachedItems(),
        throwsA(isA<AppFailure>()),
      );
      expect(singles, 1);
      expect(repo.peek('saved')!.items, hasLength(4));
    },
  );
  test(
    'unsupported bulk responses stop before a per-item request storm',
    () async {
      var calls = 0, singles = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          if (r.url.path.endsWith('/emby/Items')) return response('{}', 405);
          if (r.url.path.endsWith('/Items')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          singles++;
          return response(jsonEncode({'Id': r.url.pathSegments.last}), 200);
        }),
      )..session = syntheticSession();
      final prefs = await SharedPreferences.getInstance();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      addTearDown(() {
        repo.dispose();
        api.close();
      });
      final entries = List.generate(228, (i) => MediaItem({'Id': 'id$i'}));
      await repo.cache.put(
        repo.key('saved'),
        ItemPage(entries, entries.length),
        DateTime.now(),
      );
      await expectLater(
        repo.reconcileCachedItems(),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 2);
      expect(singles, 0);
      expect(repo.peek('saved')!.items, hasLength(228));
      metrics['unsupported_bulk'] = {
        'requests': calls,
        'detail_requests': singles,
        'retained': 228,
      };
    },
  );
}
