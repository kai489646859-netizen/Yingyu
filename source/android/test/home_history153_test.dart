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
import 'watch_resume131_test.dart' show ep;

MediaItem undated(MediaItem value) => MediaItem({
  ...value.data,
  'UserData': {
    for (final e in object(value.data['UserData']).entries)
      if (e.key != 'LastPlayedDate') e.key: e.value,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'homepage uses Resume even when sorted history differs without optional dates',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      final stale = undated(ep(14, seconds: 500));
      var latest = undated(ep(17, seconds: 310));
      final requests = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          requests.add(r.url.path.endsWith('/Resume') ? 'resume' : 'history');
          return response(
            jsonEncode({
              'Items': [
                r.url.path.endsWith('/Resume') ? stale.data : latest.data,
              ],
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
      try {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, const Duration(seconds: 500));
        expect(requests, ['resume']);
        feed.dispose();
        feed = HomeFeed(api, store, browse: browse);
        expect(feed.resume.single.id, 'e14');
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        latest = undated(ep(18, seconds: 90));
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
      } finally {
        feed.dispose();
        browse.dispose();
        api.close();
        store.dispose();
      }
    },
  );

  for (final metadata in [
    'duration',
    'date-omitted',
    'new-date',
    'older-date',
    'played',
    'play-count',
  ]) {
    test(
      'server Resume metadata changes remain authoritative after process recreation, metadata=$metadata',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = AppStore(prefs);
        var stale = ep(14, seconds: 500, date: '2026-10-20T00:00:00Z');
        final watched = MediaItem({
          ...ep(17, seconds: 310, date: '2026-10-19T00:00:00Z').data,
          'UserData': {
            ...object(
              ep(
                17,
                seconds: 310,
                date: '2026-10-19T00:00:00Z',
              ).data['UserData'],
            ),
            'Played': false,
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
        try {
          await feed.refreshResume(force: true);
          await feed.afterPlayback(watched, actualCompleted: false);
          final data = object(jsonDecode(prefs.getString(feed.cacheKey)!));
          await prefs.setString(
            feed.cacheKey,
            jsonEncode({
              'items': [
                for (final row in objects(data['items']))
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
          stale = switch (metadata) {
            'date-omitted' => undated(stale),
            'new-date' => ep(14, seconds: 500, date: '2026-10-20T00:01:00Z'),
            'older-date' => ep(14, seconds: 500, date: '2026-10-19T00:00:00Z'),
            'played' => MediaItem({
              ...stale.data,
              'UserData': {...object(stale.data['UserData']), 'Played': false},
            }),
            'play-count' => MediaItem({
              ...stale.data,
              'UserData': {...object(stale.data['UserData']), 'PlayCount': 2},
            }),
            _ => MediaItem({...stale.data, 'RunTimeTicks': 0}),
          };
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, stale.id);
          expect(feed.resume.single.resume, stale.resume);
          feed.dispose();
          feed = HomeFeed(api, store);
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, stale.id);
          stale = ep(14, seconds: 110, date: '2026-10-20T00:00:00Z');
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'e14');
          expect(feed.resume.single.resume, const Duration(seconds: 110));
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
  }

  test(
    'undated history remains read-only, respects hidden rows, and does not cross accounts',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      final stale = undated(ep(14, seconds: 500));
      final history = undated(ep(17, seconds: 310));
      final methods = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          methods.add(r.method);
          return response(
            jsonEncode({
              'Items': [
                r.url.path.endsWith('/Resume') ? stale.data : history.data,
              ],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        expect(store.localProgress(api.session!, history.id), isNull);
        await feed.lastWatchedEpisode('series');
        final saved = object(
          jsonDecode(prefs.getString(feed.verifiedHistoryKey)!),
        );
        final savedDate = object(objects(saved['items']).single['item']);
        expect(
          object(savedDate['UserData']).containsKey('LastPlayedDate'),
          isFalse,
        );
        await feed.visibility.hide(history, object(history.data['UserData']));
        await feed.refreshResume(force: true);
        expect(feed.resume, isEmpty);
        feed.dispose();
        feed = HomeFeed(api, store);
        await feed.refreshResume(force: true);
        expect(feed.resume, isEmpty);
        feed.dispose();
        api.session = syntheticSession('http://127.0.0.1:9/other-account');
        feed = HomeFeed(api, store);
        expect(feed.resume, isEmpty);
        expect(feed.recentEpisode('series'), isNull);
        expect(methods, everyElement('GET'));
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );

  test(
    'a changed undated Resume checkpoint supersedes an unchanged sorted history and survives recreation',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      var stale = undated(ep(14, seconds: 500));
      final history = undated(ep(17, seconds: 310));
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            jsonEncode({
              'Items': [
                r.url.path.endsWith('/Resume') ? stale.data : history.data,
              ],
            }),
            200,
          ),
        ),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        stale = undated(ep(14, seconds: 90));
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, const Duration(seconds: 90));
        expect((await feed.lastWatchedEpisode('series'))!.id, history.id);
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
    'agreement on the new row cannot forget an already superseded history after recreation',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      var remote = undated(ep(14, seconds: 500));
      final old = undated(ep(17, seconds: 310));
      var history = old;
      var includeResume = true;
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            jsonEncode({
              'Items': [
                if (!r.url.path.endsWith('/Resume') || includeResume)
                  r.url.path.endsWith('/Resume') ? remote.data : history.data,
              ],
            }),
            200,
          ),
        ),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        remote = undated(ep(14, seconds: 90));
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        includeResume = false;
        await feed.refreshResume(force: true);
        expect(feed.resume, isEmpty);
        expect(feed.recentEpisode('series'), isNull);
        expect((await feed.lastWatchedEpisode('series'))!.id, history.id);
        includeResume = true;
        history = remote;
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        feed.dispose();
        feed = HomeFeed(api, store);
        history = old;
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        history = undated(ep(18, seconds: 75));
        await feed.refreshResume(force: true);
        expect(
          feed.resume.single.id,
          remote.id,
          reason:
              'A changed history response cannot replace the Resume response.',
        );
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );

  test(
    'cold reconstruction restores the actual server Resume snapshot before network or details',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final stale = undated(ep(14, seconds: 500));
      final history = undated(ep(17, seconds: 310));
      var requests = 0;
      EmbyClient openApi() => EmbyClient(
        client: MockClient((r) async {
          requests++;
          return response(
            jsonEncode({
              'Items': [
                r.url.path.endsWith('/Resume') ? stale.data : history.data,
              ],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      var store = AppStore(prefs);
      var api = openApi();
      BrowseRepository repository() => BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      var browse = repository();
      var feed = HomeFeed(api, store, browse: browse);
      try {
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        expect(requests, 1);
        feed.dispose();
        browse.dispose();
        api.close();
        await store.log.flush();
        store.dispose();
        store = AppStore(prefs);
        api = openApi();
        browse = repository();
        feed = HomeFeed(api, store, browse: browse);
        expect(requests, 1);
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, const Duration(seconds: 500));
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, 'e14');
        expect(feed.resume.single.resume, const Duration(seconds: 500));
      } finally {
        feed.dispose();
        browse.dispose();
        api.close();
        await store.log.flush();
        store.dispose();
      }
    },
  );

  for (final shape in <String, dynamic>{
    'null': null,
    'empty': '',
    'blank': '   ',
    'invalid': 'unknown-date',
  }.entries) {
    test(
      'cold homepage preserves the server episode when its date becomes unknown, shape=${shape.key}',
      () async {
        final prefs = await SharedPreferences.getInstance();
        var remote = ep(14, seconds: 500, date: '2026-10-20T00:00:00Z');
        final watched = MediaItem({
          ...ep(17, seconds: 310, date: '2026-10-19T00:00:00Z').data,
          'UserData': {
            ...object(
              ep(
                17,
                seconds: 310,
                date: '2026-10-19T00:00:00Z',
              ).data['UserData'],
            ),
            'Played': false,
          },
        });
        EmbyClient openApi() => EmbyClient(
          client: MockClient(
            (r) async => response(
              jsonEncode(
                r.url.path.endsWith('/e17')
                    ? watched.data
                    : {
                        'Items': [remote.data],
                      },
              ),
              200,
            ),
          ),
        )..session = syntheticSession();
        var store = AppStore(prefs);
        var api = openApi();
        BrowseRepository repository() => BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        var browse = repository();
        var feed = HomeFeed(api, store, browse: browse);
        Future<void> restart() async {
          feed.dispose();
          browse.dispose();
          api.close();
          await store.log.flush();
          store.dispose();
          store = AppStore(prefs);
          api = openApi();
          browse = repository();
          feed = HomeFeed(api, store, browse: browse);
        }

        try {
          await feed.refreshResume(force: true);
          await feed.afterPlayback(watched, actualCompleted: false);
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
          await restart();
          expect(feed.resume.single.id, 'e14');
          remote = MediaItem({
            ...remote.data,
            'UserData': {
              ...object(remote.data['UserData']),
              'LastPlayedDate': shape.value,
            },
          });
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'e14');
          expect(feed.resume.single.resume, const Duration(seconds: 500));
          await restart();
          expect(feed.resume.single.id, 'e14');
          expect(feed.resume.single.resume, const Duration(seconds: 500));
          remote = HomeFeed.withPosition(remote, const Duration(seconds: 90));
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'e14');
          expect(feed.resume.single.resume, const Duration(seconds: 90));
          await restart();
          expect(feed.resume.single.id, 'e14');
        } finally {
          feed.dispose();
          browse.dispose();
          api.close();
          await store.log.flush();
          store.dispose();
        }
      },
    );
  }
}
