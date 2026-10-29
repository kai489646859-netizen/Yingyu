import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/unplayed_groups.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  MediaItem item(String id) =>
      MediaItem({'Id': id, 'Name': id, 'Type': 'Movie'});
  test(
    'unplayed episodes group by real series ID with no episode userdata leakage',
    () {
      MediaItem episode(String id, String series) => MediaItem({
        'Id': id,
        'Type': 'Episode',
        'SeriesId': series,
        'SeriesName': 'same title',
        'SeriesPrimaryImageTag': 'tag',
        'UserData': {'PlaybackPositionTicks': 999, 'IsFavorite': true},
      });
      final grouped = groupUnplayed([
        episode('a', 'x'),
        episode('b', 'x'),
        episode('c', 'y'),
        episode('d', ''),
        item('m'),
      ]);
      expect(grouped.map((e) => e.id), ['x', 'y', 'd', 'm']);
      expect(grouped.first.series, true);
      expect(grouped.first.data['UserData'], null);
      expect(grouped.first.overview, contains('2 集'));
    },
  );
  test(
    'old completed and rewatch observations cannot resurrect server-absent resume rows',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs),
          api = EmbyClient()..session = syntheticSession();
      var feed = HomeFeed(api, store);
      final key = feed.cacheKey;
      feed.dispose();
      await prefs.setString(
        key,
        jsonEncode({
          'items': [
            {
              'observedAt': '2020-01-01T00:00:00Z',
              'item': {
                'Id': 'old',
                'Type': 'Movie',
                'UserData': {'Played': true, 'PlaybackPositionTicks': 0},
              },
            },
          ],
        }),
      );
      feed = HomeFeed(api, store);
      expect(feed.mergeResume([item('server')]).map((e) => e.id), ['server']);
      feed.dispose();
      api.close();
      store.dispose();
    },
  );
  for (final partial in [false, true]) {
    test(
      'cache reconciliation ${partial ? "retains incomplete replies" : "evicts verified missing metadata only"}',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final api = EmbyClient(
          client: MockClient(
            (request) async => request.url.path.endsWith("/Items/gone")
                ? response("", 404)
                : response(
                    jsonEncode({
                      'Items': [item('keep').data],
                      'TotalRecordCount': partial ? 2 : 1,
                    }),
                    200,
                  ),
          ),
        )..session = syntheticSession();
        final cache = BrowseCache(prefs),
            repo = BrowseRepository(
              api,
              BrowseCache(prefs),
              BrowsePreferences(prefs),
              spacing: Duration.zero,
            );
        await repo.cache.put(
          repo.key('detail:gone'),
          ItemPage([item('gone')], 1),
          DateTime.now(),
        );
        await repo.cache.put(
          repo.key('detail:keep'),
          ItemPage([item('keep')], 1),
          DateTime.now(),
        );
        final other = jsonEncode([
          'https://another.invalid',
          'u',
          'detail:gone',
        ]);
        await repo.cache.put(
          other,
          ItemPage([item('gone')], 1),
          DateTime.now(),
        );
        await prefs.setInt('unrelated-progress', 99);
        if (partial) {
          await expectLater(
            repo.reconcileCachedItems(),
            throwsA(isA<AppFailure>()),
          );
          expect(repo.peek('detail:gone'), isNotNull);
        } else {
          expect(await repo.reconcileCachedItems(), {'gone'});
          expect(repo.peek('detail:gone'), null);
          expect(repo.peek('detail:keep'), isNotNull);
        }
        expect(repo.cache.get(other), isNotNull);
        expect(prefs.getInt('unrelated-progress'), 99);
        expect(cache.records, isEmpty);
        repo.dispose();
        api.close();
      },
    );
  }
  for (final changeAccount in [false, true]) {
    test(
      'cache batches retain all metadata on ${changeAccount ? "account switch" : "later batch failure"}',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final account = syntheticSession();
        final gate = Completer<void>();
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            calls++;
            if (calls == 2) {
              await gate.future;
              if (!changeAccount) return response('{}', 500);
            }
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }),
        )..session = account;
        final repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        await repo.cache.put(
          repo.key('all'),
          ItemPage([for (var i = 0; i < 501; i++) item('$i')], 501),
          DateTime.now(),
        );
        final pending = repo.reconcileCachedItems();
        final rejected = expectLater(pending, throwsA(isA<AppFailure>()));
        while (calls < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        if (changeAccount) api.session = syntheticSession();
        gate.complete();
        await rejected;
        expect(repo.cache.get(repo.key('all'))!.items.length, 501);
        expect(repo.reconciliationRevision, 0);
        repo.dispose();
        api.close();
      },
    );
  }
  test(
    'unlimited image quota persists and allows more than three starts in one second',
    () async {
      final prefs = InterfacePreferences(await SharedPreferences.getInstance());
      await prefs.setImageRequestLimit(0);
      expect(prefs.imageRequestLimit, 0);
      var now = DateTime.utc(2026);
      var waited = Duration.zero;
      final service = PosterFileService(
        requestLimit: 0,
        spacing: Duration.zero,
        now: () => now,
        visible: (_) => true,
        delay: (value) async {
          waited += value;
          now = now.add(value);
        },
        client: MockClient((request) async => response('image', 200)),
      );
      for (var i = 0; i < 7; i++) {
        await service.get('https://image.invalid/$i');
      }
      expect(waited, Duration.zero);
      service.requestLimit = 1;
      await service.get('https://image.invalid/limited');
      expect(waited, const Duration(seconds: 1));
      prefs.dispose();
    },
  );
}
