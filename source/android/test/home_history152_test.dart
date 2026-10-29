import 'dart:convert';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show response, syntheticSession;
import 'watch_resume131_test.dart' show ep;
import 'player_episode_menu_test.dart' show fonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'actual partial viewing metadata survives while server Resume owns the homepage after recreation',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      var stale = ep(14, seconds: 500, date: '2026-10-20T00:00:00Z');
      final watched = MediaItem({
        ...ep(17, seconds: 310, date: '2026-10-19T00:00:00Z').data,
        'UserData': {
          ...object(ep(17).data['UserData']),
          'Played': false,
          'PlaybackPositionTicks': ticks(const Duration(seconds: 310)),
          'LastPlayedDate': '2026-10-19T00:00:00Z',
        },
      });
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            jsonEncode(
              r.url.path.endsWith('/e17')
                  ? watched.data
                  : {
                      'Items': [stale.data],
                    },
            ),
            200,
          ),
        ),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      await feed.afterPlayback(watched, actualCompleted: false);
      final saved = object(jsonDecode(prefs.getString(feed.cacheKey)!));
      // objects() returns copies; preserve every receipt field while advancing beyond the old grace period.
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
      try {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, stale.resume);
        stale = ep(14, seconds: 110, date: '2026-10-20T00:00:00Z');
        await feed.refreshResume(force: true);
        expect(
          feed.resume.single.id,
          'e14',
          reason:
              'A changed remote checkpoint at the same date supersedes the old receipt baseline.',
        );
        expect(feed.resume.single.resume, const Duration(seconds: 110));
        expect(
          (await feed.lastWatchedEpisode('series'))!.id,
          'e14',
          reason:
              'Opening details must not revive an explicitly superseded local episode.',
        );
        stale = ep(14, seconds: 500, date: '2026-10-20T00:00:00Z');
        await feed.refreshResume(force: true);
        expect(
          feed.resume.single.id,
          'e14',
          reason:
              'A superseded local receipt cannot revive when an old response returns.',
        );
        feed.dispose();
        feed = HomeFeed(api, store);
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  test(
    'an automatic refresh keeps server membership while actual playback metadata is retained',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      final stale = ep(14, date: '2026-10-20T00:00:00Z');
      final watched = ep(17, seconds: 310, date: '2026-10-20T00:02:00Z');
      final detail = Completer<void>(), entered = Completer<void>();
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/e17')) {
            entered.complete();
            await detail.future;
            return response(jsonEncode(watched.data), 200);
          }
          return response(
            jsonEncode({
              'Items': r.url.path.endsWith('/Views') ? [] : [stale.data],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      final returned = feed.afterPlayback(watched, actualCompleted: false);
      await entered.future;
      await feed.refresh();
      detail.complete();
      await returned;
      try {
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, stale.resume);
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  test(
    'a remote watch during the return-detail request wins over the earlier local playback',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      var remote = ep(14, date: '2026-10-20T00:00:00Z');
      final watched = ep(17, seconds: 310, date: '2026-10-19T00:00:00Z');
      final detail = Completer<void>(), entered = Completer<void>();
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/e17')) {
            entered.complete();
            await detail.future;
            return response(jsonEncode(watched.data), 200);
          }
          return response(
            jsonEncode({
              'Items': [remote.data],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      final returned = feed.afterPlayback(watched, actualCompleted: false);
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      remote = ep(
        14,
        seconds: 100,
        date: DateTime.now().toUtc().toIso8601String(),
      );
      await feed.refreshResume(force: true);
      detail.complete();
      await returned;
      try {
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, const Duration(seconds: 100));
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  test(
    'completed global history cannot replace the explicit server Resume episode',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      final stale = ep(14, date: '2026-10-20T00:00:00Z');
      final watched = ep(17, seconds: 310, date: '2026-10-20T00:02:00Z');
      final crowd = List.generate(
        96,
        (i) => {
          ...ep(i).data,
          'Id': 'other$i',
          'SeriesId': 'other',
          'UserData': {
            'Played': true,
            'PlaybackPositionTicks': 0,
            'LastPlayedDate': '2026-10-20T01:00:00Z',
          },
        },
      );
      final api = EmbyClient(
        client: MockClient((r) async {
          final filtered = r.url.queryParameters['Filters'] == 'IsResumable';
          final items = r.url.path.endsWith('/Resume')
              ? [stale.data]
              : filtered
              ? [watched.data]
              : crowd;
          return response(jsonEncode({'Items': items}), 200);
        }),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  test(
    'phone homepage refresh does not request the complete account inventory',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      var catalogues = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Items')) catalogues++;
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      )..session = syntheticSession();
      final browse = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      final feed = HomeFeed(api, store, browse: browse);
      await feed.refresh(force: true);
      expect(catalogues, 0);
      await feed.refreshAll();
      expect(
        catalogues,
        1,
        reason:
            'Explicit library refresh still performs complete reconciliation.',
      );
      feed.dispose();
      browse.dispose();
      api.close();
      store.dispose();
    },
  );
}
