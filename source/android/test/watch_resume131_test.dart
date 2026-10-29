import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/watch_progress.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem ep(
  int n, {
  int seconds = 2388,
  String date = '2026-10-22T00:00:00Z',
}) => MediaItem({
  'Id': 'e$n',
  'Type': 'Episode',
  'Name': 'generated $n',
  'SeriesId': 'series',
  'SeriesName': 'generated',
  'SeasonId': 'season',
  'ParentIndexNumber': 1,
  'IndexNumber': n,
  'RunTimeTicks': ticks(const Duration(minutes: 55, seconds: 18)),
  'UserData': {
    'Played': true,
    'PlayCount': 1,
    'PlaybackPositionTicks': ticks(Duration(seconds: seconds)),
    'LastPlayedDate': date,
  },
});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final same in [false, true]) {
    test(
      'home and detail retain each server endpoint checkpoint without mixing positions, same=$same',
      () async {
        final store = AppStore(await SharedPreferences.getInstance());
        final current = ep(same ? 9 : 8, date: '2026-10-22T00:02:00Z');
        final stale = ep(9, seconds: 2858);
        final api = EmbyClient(
          client: MockClient(
            (r) async => response(
              jsonEncode({
                'Items': [
                  r.url.path.endsWith('/Resume') ? stale.data : current.data,
                ],
              }),
              200,
            ),
          ),
        )..session = syntheticSession();
        final feed = HomeFeed(api, store);
        try {
          await feed.refreshResume(force: true);
          final selected = await feed.lastWatchedEpisode('series');
          expect(selected!.id, current.id);
          expect(
            feed.resume.single.id,
            stale.id,
            reason:
                'The card caption belongs to the Resume endpoint, not a different history endpoint.',
          );
          expect(
            feed.resume.single.resume,
            stale.resume,
            reason: 'Never put one episode position on another episode.',
          );
          final state = WatchProgressState.resolve(
            feed.resume.single,
            api.session,
            store,
          );
          expect(state.label, contains('47:38'));
          expect(
            continueWatchingCaption(feed.resume.single, progress: state),
            contains('第 9 集'),
          );
          await feed.refreshResume(force: true);
          expect(
            feed.resume.single.id,
            stale.id,
            reason:
                'A detail read must not substitute a different endpoint into Resume.',
          );
          expect(feed.resume.single.resume, stale.resume);
        } finally {
          feed.dispose();
          api.close();
          store.dispose();
        }
      },
    );
  }

  for (final backwards in [true, false]) {
    test(
      'fresh Resume and detail history retain their independent server checkpoints, backwards=$backwards',
      () async {
        final store = AppStore(await SharedPreferences.getInstance());
        final history = ep(8, date: '2026-10-22T00:02:00Z');
        var resume = ep(9, seconds: 2858);
        final api = EmbyClient(
          client: MockClient(
            (r) async => response(
              jsonEncode({
                'Items': [
                  r.url.path.endsWith('/Resume') ? resume.data : history.data,
                ],
              }),
              200,
            ),
          ),
        )..session = syntheticSession();
        final feed = HomeFeed(api, store);
        try {
          await feed.refreshResume(force: true);
          await feed.lastWatchedEpisode('series');
          resume = ep(
            9,
            seconds: backwards ? 120 : 2900,
            date: '2026-10-22T00:02:00Z',
          );
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'e9');
          expect(feed.resume.single.resume, resume.resume);
          final focus = await feed.lastWatchedEpisode('series');
          expect(focus!.id, history.id);
          expect(focus.resume, history.resume);
          expect(feed.resume.single.resume, resume.resume);
        } finally {
          feed.dispose();
          api.close();
          store.dispose();
        }
      },
    );
  }
  test(
    'repeated detail reads keep the original stale Resume observation',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      final stale = ep(9, seconds: 2858);
      final history = ep(
        8,
      ); // Both endpoints may return the same LastPlayedDate.
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
      final feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true);
        await feed.lastWatchedEpisode('series');
        await feed.lastWatchedEpisode('series');
        await feed.refreshResume(force: true);
        expect(feed.resume.single.id, stale.id);
        expect(feed.resume.single.resume, stale.resume);
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  test(
    'metadata reconciliation only persists its display cache, never posts progress or changes other preferences and titles',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      final calls = <String>[];
      final movie = MediaItem({
        'Id': 'movie',
        'Type': 'Movie',
        'UserData': {'PlaybackPositionTicks': 1200000000},
      });
      final api = EmbyClient(
        client: MockClient((r) async {
          calls.add(r.method);
          return response(
            jsonEncode({
              'Items': r.url.path.endsWith('/Resume')
                  ? [movie.data, ep(9).data]
                  : [ep(8, date: '2026-10-22T00:03:00Z').data],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      try {
        final saved = {
          for (final k in store.prefs.getKeys())
            if (k != feed.verifiedHistoryKey && k != feed.serverResumeKey)
              k: store.prefs.get(k),
        };
        await feed.refreshResume(force: true);
        await feed.lastWatchedEpisode('series');
        expect(feed.resume.map((e) => e.id), ['movie', 'e9']);
        expect(feed.resume.first.resume, movie.resume);
        expect(calls, everyElement('GET'));
        expect({
          for (final k in store.prefs.getKeys())
            if (k != feed.verifiedHistoryKey && k != feed.serverResumeKey)
              k: store.prefs.get(k),
        }, saved);
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  test(
    'pending checkpoint caption and progress bar must use the same position',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      final account = syntheticSession();
      final item = MediaItem({
        ...ep(8, seconds: 60).data,
        'UserData': {
          ...object(ep(8, seconds: 60).data['UserData']),
          'Played': false,
        },
      });
      try {
        await store.saveProgress(
          account,
          item.id,
          const Duration(minutes: 15),
          serverBaseline: item,
        );
        final progress = WatchProgressState.resolve(item, account, store);
        expect(progress.fraction, closeTo(900 / 3318, 1e-9));
        expect(
          continueWatchingCaption(item, progress: progress),
          contains('已看 15 分钟'),
        );
      } finally {
        store.dispose();
      }
    },
  );
}
