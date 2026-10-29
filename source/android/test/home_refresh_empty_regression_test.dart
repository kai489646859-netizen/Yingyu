import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show response, syntheticSession;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'refresh preserves freshly returned home items when batch ID lookup omits them',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final lookups = <String>[];
      final live = {'Id': 'live', 'Name': '合成影片', 'Type': 'Movie'};
      final api = EmbyClient(
        client: MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/Views')) {
            return response(
              '{"Items":[{"Id":"view","Name":"电影","Type":"CollectionFolder"}]}',
              200,
            );
          }
          if (path.endsWith('/Latest')) {
            return response(jsonEncode([live]), 200);
          }
          if (path.endsWith('/Resume')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          if (request.url.queryParameters.containsKey('Ids')) {
            lookups.addAll(request.url.queryParameters['Ids']!.split(','));
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          if (path.endsWith('/Items/live')) {
            return response(jsonEncode(live), 200);
          }
          if (path.endsWith('/Items')) {
            return response(
              jsonEncode({
                'Items': [live],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          return response('', 404);
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      final store = AppStore(prefs),
          feed = HomeFeed(api, AppStore(prefs), browse: repo);
      await feed.refresh(force: true);
      expect(feed.error, isNull);
      expect(feed.sections.single.items.map((e) => e.id), ['live']);
      expect(repo.peek('latest:view')!.items.single.id, 'live');
      expect(repo.peek('views')!.items.single.id, 'view');
      expect(lookups, isNot(contains('view')));
      feed.dispose();
      feed.store.dispose();
      store.dispose();
      repo.dispose();
      api.close();
    },
  );
  for (final status in [200, 403, 404, 500]) {
    test(
      'batch omission only removes a resource after individual confirmation status=$status',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final api = EmbyClient(
          client: MockClient(
            (request) async => request.url.queryParameters.containsKey('Ids')
                ? response('{"Items":[],"TotalRecordCount":0}', 200)
                : response(status == 200 ? '{"Id":"entry"}' : '', status),
          ),
        )..session = syntheticSession();
        final repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        await repo.cache.put(
          repo.key('detail:entry'),
          ItemPage([
            MediaItem({'Id': 'entry', 'Type': 'Movie'}),
          ], 1),
          DateTime.now(),
        );
        if (status == 403 || status == 500) {
          await expectLater(
            repo.reconcileCachedItems(),
            throwsA(isA<AppFailure>()),
          );
        } else {
          expect(
            await repo.reconcileCachedItems(),
            status == 404 ? {'entry'} : isEmpty,
          );
        }
        expect(repo.peek('detail:entry') == null, status == 404);
        repo.dispose();
        api.close();
      },
    );
  }
}
