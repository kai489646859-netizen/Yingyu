// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show response, syntheticSession;
import 'home_feed_test.dart' show entry;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'completed local history survives restart but does not populate empty server Resume',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      await store.log.setEnabled(false);
      final api = EmbyClient(
        client: MockClient((_) async => response('{"Items":[]}', 200)),
      )..session = syntheticSession();
      final done = entry(
        'ep8',
        series: 'series',
        seconds: 0,
        played: true,
        date: '2026-10-18T12:00:00Z',
      );
      var feed = HomeFeed(api, store);
      await prefs.setString(
        feed.cacheKey,
        jsonEncode({
          'items': [
            {
              'item': done.data,
              'observedAt': DateTime.now()
                  .subtract(const Duration(hours: 2))
                  .toIso8601String(),
            },
          ],
        }),
      );
      feed.dispose();
      feed = HomeFeed(api, store);
      expect(feed.resume, isEmpty);
      expect(feed.cachedItems.map((i) => i.id), contains('ep8'));
      await feed.refreshResume(force: true);
      expect(feed.resume, isEmpty);
      feed.dispose();
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    },
  );
  for (final kind in [
    'newer episode',
    'newer rewatch',
    'undated episode',
    'hidden',
    'movie',
    'new account',
    'latest local',
    'completed order',
  ]) {
    test('retained completion respects $kind', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      await store.log.setEnabled(false);
      final server = <MediaItem>[];
      final api = EmbyClient(
        client: MockClient(
          (_) async => response(
            jsonEncode({'Items': server.map((x) => x.data).toList()}),
            200,
          ),
        ),
      )..session = syntheticSession();
      final completed = entry(
        'ep8',
        series: kind == 'movie' ? null : 'series',
        seconds: 0,
        played: true,
        date: '2026-10-18T12:00:00Z',
      );
      var feed = HomeFeed(api, store);
      final cache = feed.cacheKey;
      final items = [
        {
          'item': completed.data,
          'observedAt': DateTime.now()
              .subtract(const Duration(hours: 2))
              .toIso8601String(),
        },
      ];
      if (kind == 'latest local') {
        items.add({
          'item': entry(
            'ep9',
            series: 'series',
            seconds: 80,
            date: '2026-10-18T13:00:00Z',
          ).data,
          'observedAt': DateTime.now()
              .subtract(const Duration(hours: 1))
              .toIso8601String(),
        });
      }
      if (kind == 'completed order') {
        items.add({
          'item': entry(
            'otherDone',
            series: 'other',
            seconds: 0,
            played: true,
            date: '2026-10-18T13:00:00Z',
          ).data,
          'observedAt': DateTime.now()
              .subtract(const Duration(hours: 1))
              .toIso8601String(),
        });
      }
      await prefs.setString(cache, jsonEncode({'items': items}));
      if (kind == 'latest local') {
        await store.saveProgress(
          api.session!,
          'ep9',
          const Duration(seconds: 80),
          serverBaseline: entry('ep9', series: 'series', seconds: 0),
        );
      }

      if (kind == 'hidden') {
        await feed.visibility.hide(completed, {
          'LastPlayedDate': '2026-10-18T12:00:00Z',
        });
      }
      feed.dispose();
      if (kind == 'newer episode') {
        server.add(
          entry(
            'ep9',
            series: 'series',
            seconds: 50,
            date: '2026-10-18T13:00:00Z',
          ),
        );
      }
      if (kind == 'newer rewatch') {
        server.add(
          entry(
            'ep8',
            series: 'series',
            seconds: 50,
            date: '2026-10-18T13:00:00Z',
          ),
        );
      }
      if (kind == 'undated episode') {
        server.add(
          MediaItem({
            ...entry('ep9', series: 'series', seconds: 50).data,
            'UserData': {'PlaybackPositionTicks': 500000000, 'Played': false},
          }),
        );
      }
      if (kind == 'new account') {
        api.session = syntheticSession('http://127.0.0.1:9/other/emby');
      }
      feed = HomeFeed(api, store);
      await feed.refreshResume(force: true);
      if (kind == 'completed order') {
        {
          expect(feed.resume, isEmpty);
          expect(
            feed.cachedItems.map((x) => x.id),
            containsAll(['otherDone', 'ep8']),
          );
        }
      } else if (kind == 'newer rewatch') {
        expect(feed.resume.single.id, 'ep8');
        expect(feed.resume.single.resume, const Duration(seconds: 50));
      } else if (['newer episode', 'undated episode'].contains(kind)) {
        expect(feed.resume.single.id, 'ep9');
      } else {
        expect(feed.resume, isEmpty);
      }
      feed.dispose();
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    });
  }
  test(
    'completed caption keeps the state first and leaves partial captions intact',
    () {
      expect(
        continueWatchingCaption(
          entry('ep', series: 'series', seconds: 0, played: true),
        ),
        startsWith('已看完 · '),
      );
      expect(
        continueWatchingCaption(entry('movie', seconds: 0, played: true)),
        '已看完',
      );
      expect(continueWatchingCaption(entry('movie', seconds: 120)), '已看 2 分钟');
    },
  );
}
