import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession, response;
import 'home173_test.dart' show undated;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final legacy in [false, true]) {
    for (final history in ['old8', 'empty', 'failed']) {
      test(
        'server Resume omits stale played e8; history=$history legacy=$legacy; refresh/restart must match Emby order',
        () async {
          final prefs = await SharedPreferences.getInstance(),
              store = AppStore(await SharedPreferences.getInstance());
          final eight = undated(8, 2388);
          final movies = [
            for (final id in ['term', 'spider', 'snake'])
              MediaItem({
                'Id': id,
                'Type': 'Movie',
                'Name': id,
                'UserData': {
                  'Played': id != 'snake',
                  'PlaybackPositionTicks': ticks(const Duration(minutes: 17)),
                },
              }),
          ];
          var old = true, resumeReads = 0, writes = 0;
          final api = EmbyClient(
            client: MockClient((r) async {
              if (r.method != 'GET') writes++;
              if (r.url.path.endsWith('/e8')) {
                return response(jsonEncode(eight.data), 200);
              }
              if (r.url.path.endsWith('/Resume')) {
                resumeReads++;
                return response(
                  jsonEncode({
                    'Items': old
                        ? [eight.data]
                        : movies.map((e) => e.data).toList(),
                  }),
                  200,
                );
              }
              if (!old && history == 'failed') return response('{}', 503);
              return response(
                jsonEncode({
                  'Items': !old && history == 'empty' ? [] : [eight.data],
                }),
                200,
              );
            }),
          )..session = syntheticSession();
          final browse = BrowseRepository(
            api,
            BrowseCache(prefs),
            BrowsePreferences(prefs),
            spacing: Duration.zero,
          );
          var feed = HomeFeed(api, store, browse: browse);
          await feed.refreshResume(force: true);
          await feed.afterPlayback(eight, actualCompleted: false);
          expect(store.localProgress(api.session!, eight.id), isNull);
          final saved = object(jsonDecode(prefs.getString(feed.cacheKey)!));
          await prefs.setString(
            feed.cacheKey,
            jsonEncode({
              'items': [
                for (final row in objects(saved['items']))
                  {
                    if (!legacy) ...row,
                    'item': row['item'],
                    'observedAt': DateTime.now()
                        .subtract(const Duration(minutes: 2))
                        .toIso8601String(),
                  },
              ],
            }),
          );
          feed.dispose();
          feed = HomeFeed(api, store, browse: browse);
          old = false;
          final before = resumeReads;
          for (var n = 0; n < 3; n++) {
            await feed.refreshResume(force: true);
            expect(feed.resume.map((e) => e.id), movies.map((e) => e.id));
          }
          expect(
            resumeReads,
            before + 3,
            reason:
                'Each forced refresh reads the server, not the cached first card.',
          );
          feed.dispose();
          feed = HomeFeed(api, store, browse: browse);
          expect(feed.resume.map((e) => e.id), movies.map((e) => e.id));
          await feed.refreshResume(force: true);
          expect(feed.resume.map((e) => e.id), movies.map((e) => e.id));
          expect(writes, 0);
          feed.dispose();
          browse.dispose();
          api.close();
          store.dispose();
        },
      );
    }
  }
  for (final protection in ['pending', 'restart', 'grace', 'offline']) {
    test(
      'live membership follows Resume while $protection checkpoint storage is preserved',
      () async {
        final prefs = await SharedPreferences.getInstance(),
            store = AppStore(await SharedPreferences.getInstance());
        final eight = undated(8, 2388);
        var old = true;
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/e8')) {
              return response(jsonEncode(eight.data), 200);
            }
            if (!old &&
                protection == 'offline' &&
                r.url.path.endsWith('/Resume')) {
              return response('{}', 503);
            }
            return response(
              jsonEncode({
                'Items': old ? [eight.data] : [],
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        var feed = HomeFeed(api, store);
        await feed.refreshResume(force: true);
        if (protection == 'pending' || protection == 'restart') {
          await store.saveProgress(
            api.session!,
            eight.id,
            protection == 'pending'
                ? const Duration(seconds: 2400)
                : Duration.zero,
            serverBaseline: eight,
            keepZeroDisplay: protection == 'restart',
          );
        }
        await feed.afterPlayback(eight, actualCompleted: false);
        if (protection != 'grace') {
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
        }
        final checkpoint = store.localProgress(api.session!, eight.id);
        final evidence = store.watchDisplaySnapshot(api.session!, eight.id);
        old = false;
        await feed.refreshResume(force: true);
        expect(
          feed.resume.map((m) => m.id),
          protection == 'offline' ? ['e8'] : <String>[],
        );
        if (protection == 'restart') {
          expect(store.resume(api.session!, eight).position, Duration.zero);
        }
        if (protection == 'pending') {
          expect(
            store.localProgress(api.session!, eight.id),
            const Duration(seconds: 2400),
          );
        }
        expect(store.localProgress(api.session!, eight.id), checkpoint);
        expect(store.watchDisplaySnapshot(api.session!, eight.id), evidence);
        feed.dispose();
        api.close();
        store.dispose();
      },
    );
  }
}
