import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/watch_progress.dart';
import 'core_test.dart' show response, syntheticSession;
import 'home173_test.dart' show undated;

class ServerResumeFixture {
  ServerResumeFixture(this.store) {
    api = EmbyClient(
      client: MockClient((r) async {
        if (r.method != 'GET') writes++;
        if (r.url.path.endsWith('/Resume')) {
          reads++;
          if (failed) return response('{}', 503);
          return response(
            jsonEncode({'Items': raw.map((m) => m.data).toList()}),
            200,
          );
        }
        if (r.url.path.endsWith('/e8')) {
          return response(jsonEncode(eight.data), 200);
        }
        return response(
          jsonEncode({
            'Items': [history.data],
          }),
          200,
        );
      }),
    )..session = syntheticSession();
    browse = BrowseRepository(
      api,
      BrowseCache(store.prefs),
      BrowsePreferences(store.prefs),
      spacing: Duration.zero,
    );
    feed = HomeFeed(api, store, browse: browse);
  }
  final AppStore store;
  final eight = undated(8, 2388);
  late List<MediaItem> raw = [eight];
  late MediaItem history = eight;
  late final EmbyClient api;
  late final BrowseRepository browse;
  late HomeFeed feed;
  int reads = 0, writes = 0;
  bool failed = false;
  List<MediaItem> movies() => [
    for (final id in ['term', 'spider', 'snake'])
      MediaItem({
        'Id': id,
        'Type': 'Movie',
        'Name': id,
        'UserData': {
          'Played': false,
          'PlaybackPositionTicks': ticks(const Duration(minutes: 17)),
        },
      }),
  ];
  Future<void> seed(Duration? pending, {bool restart = false}) async {
    await feed.refreshResume(force: true);
    if (pending != null) {
      await store.saveProgress(
        api.session!,
        eight.id,
        pending,
        serverBaseline: eight,
        keepZeroDisplay: restart,
      );
    }
    await feed.afterPlayback(eight, actualCompleted: false);
    final saved = object(jsonDecode(store.prefs.getString(feed.cacheKey)!));
    await store.prefs.setString(
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
    feed = HomeFeed(api, store, browse: browse);
  }

  void close() {
    feed.dispose();
    browse.dispose();
    api.close();
    store.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final pending in [const Duration(seconds: 2388), Duration.zero]) {
    test(
      'live server list is exact even with an old protected checkpoint=$pending; checkpoint survives',
      () async {
        final f = ServerResumeFixture(
          AppStore(await SharedPreferences.getInstance()),
        );
        await f.seed(pending, restart: pending == Duration.zero);
        final checkpoint = f.store.localProgress(f.api.session!, f.eight.id);
        f.raw = f.movies();
        for (var n = 0; n < 3; n++) {
          await f.feed.refreshResume(force: true);
          expect(f.feed.resume.map((m) => m.id), f.raw.map((m) => m.id));
          expect(f.store.localProgress(f.api.session!, f.eight.id), checkpoint);
        }
        f.feed.dispose();
        f.feed = HomeFeed(f.api, f.store, browse: f.browse);
        expect(f.feed.resume.map((m) => m.id), f.raw.map((m) => m.id));
        f.feed.dispose();
        f.feed = HomeFeed(f.api, f.store);
        expect(
          f.feed.resume.map((m) => m.id),
          f.raw.map((m) => m.id),
          reason:
              'A raw server snapshot must survive without the browse cache; local history is not the snapshot.',
        );
        expect(f.writes, 0);
        f.close();
      },
    );
  }
  test(
    'server order and position are not overwritten by an unsynced later checkpoint, including card rendering',
    () async {
      final f = ServerResumeFixture(
        AppStore(await SharedPreferences.getInstance()),
      );
      await f.seed(const Duration(seconds: 2400));
      f.raw = [...f.movies(), f.eight];
      await f.feed.refreshResume(force: true);
      expect(f.feed.resume.map((m) => m.id), f.raw.map((m) => m.id));
      final shown = f.feed.resume.last;
      expect(shown.resume, f.eight.resume);
      expect(
        WatchProgressState.resolve(shown, f.api.session, f.store).position,
        f.eight.resume,
      );
      expect(
        f.store.resume(f.api.session!, f.eight).position,
        const Duration(seconds: 2400),
        reason:
            'The player still has its real unsynced checkpoint; only the server-owned card ignores it.',
      );
      expect(f.writes, 0);
      f.close();
    },
  );
  test(
    'sorted episode history cannot substitute a different episode into server Resume',
    () async {
      final f = ServerResumeFixture(
        AppStore(await SharedPreferences.getInstance()),
      );
      f.history = undated(13, 1200);
      await f.feed.refreshResume(force: true);
      expect(f.feed.resume.single.id, 'e8');
      expect(f.feed.resume.single.resume, f.eight.resume);
      f.close();
    },
  );
  test(
    'last live server list survives a failed refresh without reviving local history',
    () async {
      final f = ServerResumeFixture(
        AppStore(await SharedPreferences.getInstance()),
      );
      await f.seed(const Duration(seconds: 2388));
      f.raw = f.movies();
      await f.feed.refreshResume(force: true);
      f.failed = true;
      await f.feed.refreshResume(force: true);
      expect(f.feed.resume.map((m) => m.id), f.raw.map((m) => m.id));
      expect(f.feed.resumeError, isNotNull);
      expect(
        f.store.localProgress(f.api.session!, f.eight.id),
        const Duration(seconds: 2388),
      );
      f.close();
    },
  );
}
