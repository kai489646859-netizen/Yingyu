import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession, response;
import 'watch_resume131_test.dart' show ep;

MediaItem undated(int n, int seconds) => MediaItem({
  ...ep(n, seconds: seconds).data,
  'UserData': {
    ...object(ep(n).data['UserData'])..remove('LastPlayedDate'),
    'PlaybackPositionTicks': ticks(Duration(seconds: seconds)),
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('mixed history cannot replace the independent Resume episode', () async {
    final store = AppStore(await SharedPreferences.getInstance());
    final eight = undated(8, 2388), twelve = undated(12, 0);
    final thirteen = MediaItem({
      ...undated(13, 1200).data,
      'UserData': {
        'Played': false,
        'PlaybackPositionTicks': ticks(const Duration(seconds: 1200)),
      },
    });
    final api = EmbyClient(
      client: MockClient(
        (r) async => response(
          jsonEncode({
            'Items': r.url.path.endsWith('/Resume')
                ? [eight.data]
                : r.url.queryParameters['Filters'] == 'IsPlayed'
                ? [twelve.data]
                : r.url.queryParameters['Filters'] == 'IsResumable'
                ? [thirteen.data, eight.data]
                : [thirteen.data, twelve.data, eight.data],
          }),
          200,
        ),
      ),
    )..session = syntheticSession();
    final feed = HomeFeed(api, store);
    await feed.refreshResume(force: true);
    expect(feed.resume.single.id, 'e8');
    expect(feed.resume.single.resume, eight.resume);
    feed.dispose();
    api.close();
    store.dispose();
  });
  test(
    'an old first rewatch cannot stay pinned when fresh server resume starts with other movies',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      final eight = undated(8, 2388), thirteen = undated(13, 1200);
      var old = true;
      final movies = [
        for (final id in ['term', 'spider'])
          MediaItem({
            'Id': id,
            'Name': id,
            'Type': 'Movie',
            'UserData': {
              'Played': false,
              'PlaybackPositionTicks': ticks(const Duration(minutes: 17)),
            },
          }),
      ];
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            jsonEncode(
              r.url.path.endsWith('/e8')
                  ? eight.data
                  : {
                      'Items': r.url.path.endsWith('/Resume')
                          ? (old
                                ? [eight.data]
                                : movies.map((m) => m.data).toList())
                          : [old ? eight.data : thirteen.data],
                    },
            ),
            200,
          ),
        ),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      await feed.afterPlayback(eight, actualCompleted: false);
      final saved = object(jsonDecode(prefs.getString(feed.cacheKey)!));
      await prefs.setString(
        feed.cacheKey,
        jsonEncode({
          'items': [
            for (final row in objects(saved['items']))
              {
                ...row,
                'observedAt': DateTime.now()
                    .subtract(const Duration(days: 1))
                    .toIso8601String(),
              },
          ],
        }),
      );
      feed.dispose();
      feed = HomeFeed(api, store);
      old = false;
      for (var n = 0; n < 3; n++) {
        await feed.refreshResume(force: true);
        expect(feed.resume.map((m) => m.id), ['term', 'spider']);
        expect(feed.recentEpisode('series'), isNull);
      }
      feed.dispose();
      feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      expect(feed.resume.map((m) => m.id), ['term', 'spider']);
      feed.dispose();
      api.close();
      store.dispose();
    },
  );
  test(
    'completed history cannot replace Resume8 or crowd an unplayed next-up',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      final eight = undated(8, 2388), thirteen = undated(13, 0);
      var raw = eight;
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            jsonEncode({
              'Items': [
                !r.url.path.endsWith('/Resume') &&
                        !r.url.queryParameters.containsKey('Filters')
                    ? thirteen.data
                    : raw.data,
              ],
            }),
            200,
          ),
        ),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e8');
      expect(feed.resume.single.resume, eight.resume);
      raw = MediaItem({
        ...undated(14, 0).data,
        'UserData': {'Played': false, 'PlaybackPositionTicks': 0},
      });
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e14');
      feed.dispose();
      api.close();
      store.dispose();
    },
  );
  test(
    'undated history remains independent from Resume8 across refresh and restart without writes',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      final eight = undated(8, 2388), thirteen = undated(13, 1200);
      var history = eight;
      var writes = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.method != 'GET') writes++;
          return response(
            jsonEncode(
              r.url.path.endsWith('/e8')
                  ? eight.data
                  : {
                      'Items': [
                        r.url.path.endsWith('/Resume')
                            ? eight.data
                            : history.data,
                      ],
                    },
            ),
            200,
          );
        }),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      await feed.afterPlayback(eight, actualCompleted: false);
      final saved = object(jsonDecode(prefs.getString(feed.cacheKey)!));
      await prefs.setString(
        feed.cacheKey,
        jsonEncode({
          'items': [
            for (final row in objects(saved['items']))
              {
                ...row,
                'observedAt': DateTime.now()
                    .subtract(const Duration(days: 1))
                    .toIso8601String(),
              },
          ],
        }),
      );
      feed.dispose();
      feed = HomeFeed(api, store);
      history = thirteen;
      for (var n = 0; n < 3; n++) {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e8');
        expect(feed.resume.single.resume, eight.resume);
        expect(
          feed.recentEpisode('series')!.id,
          feed.resume.where((m) => m.type == 'Episode').isEmpty ? 'e13' : 'e8',
        );
      }
      feed.dispose();
      feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e8');
      expect(writes, 0);
      feed.dispose();
      api.close();
      store.dispose();
    },
  );

  test(
    'a server Resume8 remains unchanged by another history checkpoint',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      final eight = undated(8, 2388);
      var history = undated(13, 1200);
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            jsonEncode(
              r.url.path.endsWith('/e8')
                  ? eight.data
                  : {
                      'Items': [
                        r.url.path.endsWith('/Resume')
                            ? eight.data
                            : history.data,
                      ],
                    },
            ),
            200,
          ),
        ),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e8');
      await feed.afterPlayback(eight, actualCompleted: false);
      final saved = object(jsonDecode(prefs.getString(feed.cacheKey)!));
      await prefs.setString(
        feed.cacheKey,
        jsonEncode({
          'items': [
            for (final row in objects(saved['items']))
              {
                ...row,
                'observedAt': DateTime.now()
                    .subtract(const Duration(minutes: 2))
                    .toIso8601String(),
              },
          ],
        }),
      );
      feed.dispose();
      feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e8');
      history = undated(13, 1500);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e8');
      expect(feed.resume.single.resume, eight.resume);
      feed.dispose();
      api.close();
      store.dispose();
    },
  );
}
