import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late EmbyClient api;
  late BrowseRepository repo;
  final calls = <String>[];
  var fail = false;
  final rows = <String, List<Json>>{
    'series': [
      {'Id': 'show', 'Name': '剧集内容', 'Type': 'Series'},
      {'Id': 'shared', 'Name': '共同内容', 'Type': 'Series'},
    ],
    'anime': [
      {'Id': 'anime-show', 'Name': '动漫内容', 'Type': 'Series'},
      {'Id': 'shared', 'Name': '共同内容', 'Type': 'Series'},
    ],
    'empty': [],
  };
  BrowseRepository create() => BrowseRepository(
    api,
    BrowseCache(prefs),
    BrowsePreferences(prefs),
    spacing: Duration.zero,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    calls.clear();
    fail = false;
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/Views')) {
          return response(
            jsonEncode({
              'Items': [
                for (final id in rows.keys)
                  {
                    'Id': id,
                    'Name': id,
                    'Type': 'CollectionFolder',
                    'IsFolder': true,
                  },
              ],
            }),
            200,
          );
        }
        final parent = request.url.queryParameters['ParentId'] ?? 'all';
        calls.add(parent);
        if (fail) return response('{}', 503);
        final items = rows[parent] ?? [];
        return response(
          jsonEncode({'Items': items, 'TotalRecordCount': items.length}),
          200,
        );
      }),
    )..session = syntheticSession();
    repo = create();
    await repo.libraries();
  });
  tearDown(() {
    repo.dispose();
    api.close();
  });
  test(
    'all catalogue partitions actual server libraries, including overlap and empty libraries',
    () async {
      final all = await repo.catalogue();
      expect(all.total, 3);
      expect(calls, ['series', 'anime', 'empty']);
      for (final scope in rows.keys) {
        final result = await repo.catalogue(parent: scope);
        expect(
          result.items.map((i) => i.id),
          unorderedEquals(rows[scope]!.map((i) => i['Id'])),
        );
      }
      expect(calls, hasLength(3));
      final restarted = create();
      expect((await restarted.catalogue(parent: 'anime')).total, 2);
      expect((await restarted.catalogue(parent: 'empty')).total, 0);
      expect(calls, hasLength(3));
      restarted.dispose();
    },
  );
  test(
    'failed refresh preserves complete partition cache and account isolation',
    () async {
      await repo.catalogue();
      fail = true;
      await expectLater(
        repo.catalogue(force: true),
        throwsA(isA<AppFailure>()),
      );
      expect(repo.peekCatalogue('anime', 'alphabet')!.total, 2);
      api.session = Session(
        base: Uri.parse('https://other.invalid'),
        userId: 'other',
        token: 'fixture',
        username: 'fixture',
        deviceId: 'fixture',
      );
      final other = create();
      expect(other.peekCatalogue('anime', 'alphabet'), isNull);
      await expectLater(
        repo.catalogue(parent: 'anime'),
        throwsA(isA<AppFailure>()),
      );
      other.dispose();
    },
  );
  test(
    'older complete cache migrates membership once; newer individual refresh wins',
    () async {
      await repo.cache.put(
        repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
        ItemPage([MediaItem(rows['series']!.first)], 1),
        DateTime.now(),
      );
      await repo.catalogue();
      expect(calls, ['series', 'anime', 'empty']);
      await repo.cache.put(
        repo.key(BrowseRepository.catalogueKey('anime', 'alphabet')),
        ItemPage([
          MediaItem({'Id': 'new', 'Name': '新动漫'}),
        ], 1),
        DateTime.now().add(const Duration(milliseconds: 1)),
      );
      expect(repo.peekCatalogue('anime', 'alphabet')!.items.single.id, 'new');
    },
  );
}
