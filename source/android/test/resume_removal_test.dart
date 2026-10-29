// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/background_work.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/resume_visibility.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show response, syntheticSession;
import 'home_feed_test.dart' show entry;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  final movie = entry('m');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
  });
  EmbyClient client(Future<http.Response> Function(http.Request) handle) =>
      EmbyClient(client: MockClient(handle))..session = syntheticSession();
  http.Response page(List<MediaItem> items) => response(
    jsonEncode({
      'Items': items.map((item) => item.data).toList(),
      'TotalRecordCount': items.length,
    }),
    200,
  );

  test(
    'remove uses authenticated HideFromResume and preserves every progress key after restart',
    () async {
      final calls = <http.Request>[];
      final api = client((request) async {
        calls.add(request);
        if (request.method == 'POST') {
          return response(jsonEncode(movie.data['UserData']), 200);
        }
        if (request.url.path.endsWith('/Resume')) {
          return page([movie]); // stale server snapshot
        }
        return response(jsonEncode(movie.data), 200);
      });
      final feed = HomeFeed(api, store);
      await store.saveProgress(
        api.session!,
        movie.id,
        const Duration(seconds: 95),
        serverBaseline: movie,
      );
      await feed.afterPlayback(movie);
      final before = {
        for (final key in store.prefs.getKeys())
          if (key.contains('progress')) key: store.prefs.get(key),
      };
      calls.clear();
      await feed.removeFromResume(movie);
      expect(feed.resume, isEmpty);
      final post = calls.where((call) => call.method == 'POST').single;
      expect(
        post.url.path,
        endsWith('/Users/synthetic-user/Items/m/HideFromResume'),
      );
      expect(post.url.queryParameters, {'Hide': 'true'});
      expect(post.body, isEmpty);
      expect(
        post.headers['X-Emby-Token'] ?? post.headers['x-emby-token'],
        'SYNTHETIC_TOKEN',
      );
      expect(
        calls.any(
          (call) =>
              call.url.path.endsWith('/UserData') ||
              call.url.path.contains('PlayedItems'),
        ),
        false,
      );
      for (final item in before.entries) {
        expect(store.prefs.get(item.key), item.value);
      }
      expect(
        store.localProgress(api.session!, 'm'),
        const Duration(seconds: 95),
      );
      expect(HomeFeed(api, store).mergeResume([movie]), isEmpty);
      expect(
        store.resume(api.session!, movie).position,
        const Duration(seconds: 95),
      );
      feed.dispose();
      api.close();
    },
  );
  for (final status in [401, 403, 500]) {
    test(
      'failed removal $status leaves the row and its progress intact',
      () async {
        final api = client((_) async => response('{}', status));
        final feed = HomeFeed(api, store)..resume = [movie];
        await expectLater(
          feed.removeFromResume(movie),
          throwsA(isA<AppFailure>()),
        );
        expect(feed.resume.single.id, movie.id);
        expect(feed.allowsResume(movie), true);
        expect(feed.removing(movie), false);
        feed.dispose();
        api.close();
      },
    );
  }
  test(
    'rapid duplicate remove submits once and stale in-flight Resume cannot restore it',
    () async {
      final resume = Completer<http.Response>(),
          hide = Completer<http.Response>();
      final started = Completer<void>();
      var posts = 0;
      final api = client((request) async {
        if (request.method == 'POST') {
          posts++;
          return hide.future;
        }
        if (!started.isCompleted) started.complete();
        return resume.future;
      });
      final feed = HomeFeed(api, store)..resume = [movie];
      final refresh = feed.refreshResume(force: true);
      await started.future;
      final removal = feed.removeFromResume(movie);
      await feed.removeFromResume(movie);
      hide.complete(response(jsonEncode(movie.data['UserData']), 200));
      await removal;
      resume.complete(page([movie]));
      await refresh;
      expect(posts, 1);
      expect(feed.resume, isEmpty);
      feed.dispose();
      api.close();
    },
  );
  test(
    'successful removal does not show the invalidated repository refresh as an error',
    () async {
      final stale = Completer<http.Response>(), started = Completer<void>();
      final api = client((request) async {
        if (request.method == 'POST') {
          return response(jsonEncode(movie.data['UserData']), 200);
        }
        started.complete();
        return stale.future;
      });
      final browse = BrowseRepository(
        api,
        BrowseCache(store.prefs),
        BrowsePreferences(store.prefs),
        spacing: Duration.zero,
      );
      final feed = HomeFeed(api, store, browse: browse)..resume = [movie];
      final refresh = feed.refreshResume(force: true);
      await started.future;
      await feed.removeFromResume(movie);
      stale.complete(page([movie]));
      await refresh;
      expect(feed.resume, isEmpty);
      expect(feed.resumeError, isNull);
      expect(feed.resumeLoading, false);
      feed.dispose();
      browse.dispose();
      api.close();
    },
  );
  test(
    'late afterPlayback detail cannot undo a later successful removal',
    () async {
      final detail = Completer<http.Response>(), started = Completer<void>();
      final api = client((request) async {
        if (request.method == 'POST') {
          return response(jsonEncode(movie.data['UserData']), 200);
        }
        if (request.url.path.endsWith('/Resume')) return page([]);
        started.complete();
        return detail.future;
      });
      final feed = HomeFeed(api, store)..resume = [movie];
      final old = feed.afterPlayback(movie);
      await started.future;
      await feed.removeFromResume(movie);
      detail.complete(response(jsonEncode(movie.data), 200));
      await old;
      expect(feed.resume, isEmpty);
      expect(feed.allowsResume(movie), false);
      feed.dispose();
      api.close();
    },
  );
  test(
    'removing another title preserves the just-closed playback observation',
    () async {
      final other = entry('other');
      final detail = Completer<http.Response>(), started = Completer<void>();
      final api = client((request) async {
        if (request.method == 'POST') {
          return response(jsonEncode(movie.data['UserData']), 200);
        }
        if (request.url.path.endsWith('/Resume')) return page([]);
        started.complete();
        return detail.future;
      });
      final feed = HomeFeed(api, store)..resume = [movie];
      final observation = feed.afterPlayback(other);
      await started.future;
      await feed.removeFromResume(movie);
      detail.complete(response(jsonEncode(other.data), 200));
      await observation;
      expect(feed.resume, isEmpty);
      expect(feed.cachedItems.map((item) => item.id), contains('other'));
      expect(feed.allowsResume(movie), false);
      feed.dispose();
      api.close();
    },
  );
  test(
    'series display exclusion never deletes episode progress or crosses accounts and servers',
    () async {
      final account = syntheticSession();
      final first = entry('e1', series: 'series'),
          second = entry('e2', series: 'series');
      final hidden = ResumeVisibility(store.prefs, account);
      await store.saveProgress(account, first.id, const Duration(seconds: 80));
      await store.saveProgress(
        account,
        second.id,
        const Duration(seconds: 120),
      );
      await hidden.hide(first, object(first.data['UserData']));
      expect(hidden.allows(second), false);
      final other = Session(
        base: account.base,
        userId: 'other',
        token: 'FAKE',
        username: 'Other',
        deviceId: 'fake',
        serverId: 'fake',
      );
      expect(ResumeVisibility(store.prefs, other).allows(first), true);
      expect(
        ResumeVisibility(
          store.prefs,
          syntheticSession('https://other.invalid'),
        ).allows(first),
        true,
      );
      expect(
        store.localProgress(account, first.id),
        const Duration(seconds: 80),
      );
      expect(
        store.localProgress(account, second.id),
        const Duration(seconds: 120),
      );
    },
  );
  test(
    'same or older server date stays hidden; genuinely newer server playback can reappear',
    () async {
      var current = movie;
      final api = client(
        (request) async => request.method == 'POST'
            ? response(jsonEncode(movie.data['UserData']), 200)
            : page([current]),
      );
      final feed = HomeFeed(api, store)..resume = [movie];
      await feed.removeFromResume(movie);
      expect(feed.resume, isEmpty);
      current = entry('m', date: '2026-10-08T00:00:00Z', seconds: 120);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 120));
      expect(HomeFeed(api, store).allowsResume(current), true);
      feed.dispose();
      api.close();
    },
  );
  test(
    'new actual playback removes local display exclusion without clearing watch position',
    () async {
      final api = client(
        (request) async => request.url.path.endsWith('/Resume')
            ? page([movie])
            : response(jsonEncode(movie.data), 200),
      );
      final feed = HomeFeed(api, store);
      await feed.visibility.hide(movie, object(movie.data['UserData']));
      await feed.afterPlayback(movie);
      expect(feed.resume.single.id, 'm');
      expect(feed.resume.single.resume, const Duration(seconds: 60));
      feed.dispose();
      api.close();
    },
  );
  test(
    'a late removal only stores visibility for its captured account',
    () async {
      final hide = Completer<http.Response>();
      final api = client((_) => hide.future);
      final oldAccount = api.session!;
      final feed = HomeFeed(api, store)..resume = [movie];
      final job = feed.removeFromResume(movie);
      await Future<void>.delayed(Duration.zero);
      feed.dispose();
      final other = Session(
        base: oldAccount.base,
        userId: 'other',
        token: 'FAKE',
        username: 'Other',
        deviceId: 'fake',
        serverId: 'fake',
      );
      api.session = other;
      hide.complete(response(jsonEncode(movie.data['UserData']), 200));
      await job;
      expect(ResumeVisibility(store.prefs, other).allows(movie), true);
      expect(ResumeVisibility(store.prefs, oldAccount).allows(movie), false);
      api.close();
    },
  );
  test(
    'resume cache invalidation rejects older request and allows a fresh coalesced request',
    () async {
      final stale = Completer<http.Response>(), started = Completer<void>();
      var calls = 0;
      final api = client((_) async {
        if (++calls == 1) {
          started.complete();
          return stale.future;
        }
        return page([]);
      });
      final cache = BrowseCache(store.prefs);
      final browse = BrowseRepository(
        api,
        cache,
        BrowsePreferences(store.prefs),
        spacing: Duration.zero,
      );
      final first = browse.resume(force: true);
      final rejected = expectLater(first, throwsA(isA<BackgroundPaused>()));
      await started.future;
      browse.invalidateResume();
      final fresh = browse.resume(force: true);
      stale.complete(page([movie]));
      await rejected;
      expect((await fresh).items, isEmpty);
      expect(browse.peek('resume:0:18')!.items, isEmpty);
      expect(calls, 2);
      browse.dispose();
      api.close();
    },
  );
}
