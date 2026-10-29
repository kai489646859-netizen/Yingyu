// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
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
import 'home_feed_test.dart' show entry;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late BrowseRepository browse;
  late List<MediaItem> server;
  var fail = false;
  final feeds = <HomeFeed>[];
  HomeFeed open() {
    final feed = HomeFeed(api, store, browse: browse);
    feeds.add(feed);
    return feed;
  }

  Future<void> seedRecent(MediaItem item) async {
    await store.prefs.setString(
      open().cacheKey,
      jsonEncode({
        'items': [
          {
            'item': item.data,
            'observedAt': DateTime.now()
                .subtract(const Duration(hours: 2))
                .toIso8601String(),
          },
        ],
      }),
    );
  }

  Future<void> seedServer(List<MediaItem> items) async {
    // This fixture explicitly represents a later server response. Two calls to
    // DateTime.now can share the same Windows clock tick; that is not evidence
    // that a cache record is newer than the canonical server snapshot.
    final snapshot = object(
      jsonDecode(store.prefs.getString(open().serverResumeKey) ?? '{}'),
    );
    final previous = DateTime.tryParse('${snapshot['at']}');
    final now = DateTime.now();
    final at = previous != null && !now.isAfter(previous)
        ? previous.add(const Duration(microseconds: 1))
        : now;
    await browse.cache.put(
      browse.key('resume:0:18'),
      ItemPage(items, items.length),
      at,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    fail = false;
    server = [];
    api = EmbyClient(
      client: MockClient(
        (_) async => fail
            ? response('{}', 503)
            : response(
                jsonEncode({'Items': server.map((e) => e.data).toList()}),
                200,
              ),
      ),
    )..session = syntheticSession();
    browse = BrowseRepository(
      api,
      BrowseCache(store.prefs),
      BrowsePreferences(store.prefs),
      spacing: Duration.zero,
    );
  });
  tearDown(() async {
    for (final feed in feeds) {
      feed.dispose();
    }
    feeds.clear();
    browse.dispose();
    api.close();
    await store.log.flush();
    store.dispose();
  });

  test(
    'startup uses the last server order and episode, unchanged refresh cannot reshuffle',
    () async {
      await seedRecent(entry('old-episode', series: 'series', seconds: 200));
      server = [
        entry('other-movie'),
        entry('new-episode', series: 'series', seconds: 40),
      ];
      await seedServer(server);
      final feed = open();
      expect(feed.resume.map((e) => e.id), ['other-movie', 'new-episode']);
      expect(feed.resume.last.resume, const Duration(seconds: 40));
      await feed.refreshResume(force: true);
      expect(feed.resume.map((e) => e.id), ['other-movie', 'new-episode']);
      expect(open().resume.map((e) => e.id), ['other-movie', 'new-episode']);
    },
  );

  test(
    'startup cannot flash old progress or resurrect an item from a known empty resume snapshot',
    () async {
      await seedRecent(entry('movie', seconds: 800));
      server = [entry('movie', seconds: 25, date: '2026-10-07T12:00:00Z')];
      await seedServer(server);
      final feed = open();
      expect(feed.resume.single.resume, const Duration(seconds: 25));
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 25));
      server = [];
      await seedServer(server);
      expect(open().resume, isEmpty);
    },
  );

  for (final newer in [false, true]) {
    test('startup compares exact snapshot timestamps; newer=$newer', () async {
      final movie = entry('movie', seconds: 25);
      final at = DateTime.utc(2026, 10, 29, 0, 0, 0, 0, 500);
      await store.prefs.setString(
        open().serverResumeKey,
        jsonEncode({
          'version': 1,
          'at': at.toIso8601String(),
          'items': [movie.data],
        }),
      );
      await browse.cache.put(
        browse.key('resume:0:18'),
        ItemPage(const [], 0),
        newer ? at.add(const Duration(microseconds: 1)) : at,
      );
      final feed = open();
      expect(feed.resume.map((e) => e.id), newer ? isEmpty : ['movie']);
    });
  }

  test(
    'server order survives startup without changing a pending local checkpoint',
    () async {
      final recent = entry('movie', seconds: 100);
      await seedRecent(recent);
      server = [entry('other'), recent];
      await seedServer(server);
      await store.saveProgress(
        api.session!,
        'movie',
        const Duration(seconds: 600),
        serverBaseline: recent,
      );
      final feed = open();
      expect(feed.resume.first.id, 'other');
      expect(feed.resume.last.resume, const Duration(seconds: 100));
      await feed.refreshResume(force: true);
      expect(feed.resume.last.resume, const Duration(seconds: 100));
      expect(
        store.localProgress(api.session!, 'movie'),
        const Duration(seconds: 600),
      );
      // A real server update still replaces the previous server snapshot.
      server = [
        entry('new-movie'),
        entry('movie', seconds: 20, date: '2026-10-07T12:00:00Z'),
      ];
      await feed.refreshResume(force: true);
      expect(feed.resume.last.resume, const Duration(seconds: 20));
      expect(feed.resume.map((e) => e.id), contains('new-movie'));
    },
  );

  test(
    'without a server snapshot startup retains offline metadata without fabricating Resume cards',
    () async {
      await seedRecent(entry('offline-movie', seconds: 80));
      final feed = open();
      expect(feed.resume, isEmpty);
      expect(feed.cachedItems.single.id, 'offline-movie');
      fail = true;
      await feed.refreshResume(force: true);
      expect(feed.resume, isEmpty);
      expect(feed.cachedItems.single.id, 'offline-movie');
      expect(feed.resumeError, isNotNull);
    },
  );
}
