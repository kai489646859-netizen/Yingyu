import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'complete catalogue sorts once, persists prepared titles and survives reopening',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final calls = <Uri>[];
      var rename = false;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls.add(r.url);
          expect(r.url.path.endsWith('/Items'), true);
          expect(r.url.queryParameters.containsKey('Limit'), false);
          expect(
            r.url.queryParameters['Fields'],
            isNot(contains('MediaSources')),
          );
          return response(
            jsonEncode({
              'Items': [
                {'Id': 'z', 'Name': rename ? '白日梦' : '最后一部', 'Type': 'Movie'},
                {'Id': 'a', 'Name': '阿丽塔', 'Type': 'Movie'},
                {'Id': 'd', 'Name': '斗破苍穹', 'Type': 'Series'},
              ],
              'TotalRecordCount': 3,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final cache = BrowseCache(prefs);
      var repo = BrowseRepository(
        api,
        cache,
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      final first = await repo.catalogue();
      expect(first.items.map((item) => item.id), ['a', 'd', 'z']);
      expect(selectCatalog((first.items, 'doupo', null)).items.single.id, 'd');
      expect(selectCatalog((first.items, '', null)).offsets, {
        'A': 0,
        'D': 1,
        'Z': 2,
      });
      await repo.catalogue();
      repo.dispose();
      repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      final reopened = await repo.catalogue();
      expect(calls.length, 1);
      expect(reopened.items.map((e) => e.id), ['a', 'd', 'z']);
      final refreshed = await repo.catalogue(force: true);
      expect(refreshed.items.map((e) => e.id), ['a', 'd', 'z']);
      expect(
        identical(
          refreshed.items.first.data[titleKeysField],
          reopened.items.first.data[titleKeysField],
        ),
        true,
      );
      rename = true;
      final changed = await repo.catalogue(force: true);
      expect(changed.items.map((e) => e.id), ['a', 'z', 'd']);
      expect(selectCatalog((changed.items, 'bai', null)).items.single.id, 'z');
      expect(
        selectCatalog((changed.items, '', null)).offsets.containsKey('Z'),
        false,
      );
      repo.dispose();
      api.close();
    },
  );

  test(
    'server page cap is completed automatically and a repeated page is a real error',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final starts = <int>[];
      var broken = false;
      final api = EmbyClient(
        client: MockClient((r) async {
          final at = int.parse(r.url.queryParameters['StartIndex']!);
          starts.add(at);
          return response(
            jsonEncode({
              'Items': List.generate(
                at == 0 || broken ? 2 : 1,
                (i) => {
                  'Id': '${broken ? i : at + i}',
                  'Name': '影片 ${broken ? i : at + i}',
                },
              ),
              'TotalRecordCount': broken ? 6 : 3,
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
      expect((await repo.catalogue()).items.length, 3);
      expect(starts, [0, 2]);
      broken = true;
      await expectLater(
        repo.catalogue(force: true),
        throwsA(isA<AppFailure>()),
      );
      expect(starts, [0, 2, 0, 2]);
      expect((await repo.catalogue()).items.length, 3);
      repo.dispose();
      api.close();
    },
  );

  test(
    '10000 synthetic titles are prepared off the UI isolate with no media access',
    () async {
      final items = List.generate(
        10000,
        (i) => MediaItem({
          'Id': 'm$i',
          'Name': '${i.isEven ? "阿丽塔" : "最后的旅程"} $i',
          'Type': 'Movie',
        }),
      );
      var heartbeats = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 2),
        (_) => heartbeats++,
      );
      final watch = Stopwatch()..start();
      final result = await compute(prepareCatalog, items);
      watch.stop();
      heartbeat.cancel();
      expect(result.length, 10000);
      expect(heartbeats, greaterThan(0));
      final selection = await compute(selectCatalog, (result, '', null));
      expect(selection.offsets, {'A': 0, 'Z': 5000});
      final file = File('build/catalog-synthetic.json')
        ..parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode({
          'items': result.length,
          'preparation_ms': watch.elapsedMilliseconds,
          'ui_isolate_heartbeats': heartbeats,
          'device_fps_measured': false,
        }),
      );
    },
  );
}
