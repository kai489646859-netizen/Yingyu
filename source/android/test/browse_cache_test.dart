import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/alphabet.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'core_test.dart' show syntheticSession, response;

class _AbortedPosterClient extends http.BaseClient {
  int calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    final abort = (request as http.Abortable).abortTrigger!;
    await abort;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late DateTime now;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime.utc(2026, 10, 7);
  });
  test(
    'in-flight detail artwork aborts offscreen; another visible owner keeps it alive',
    () async {
      const url = 'https://mock.invalid/detail-background?tag=test';
      final first = Object(), second = Object();
      final client = _AbortedPosterClient();
      final service = PosterFileService(client: client, spacing: Duration.zero);
      PosterDemand.set(first, url);
      PosterDemand.set(second, url);
      final request = service.get(url);
      final stopped = expectLater(
        request,
        throwsA(isA<http.RequestAbortedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      PosterDemand.set(first, null);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(client.calls, 1); // second view still owns the download
      PosterDemand.set(second, null);
      await stopped;
      PosterDemand.set(first, url);
      final again = expectLater(
        service.get(url),
        throwsA(isA<http.RequestAbortedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        client.calls,
        2,
      ); // scrolling cancellation did not impose server backoff
      PosterDemand.set(first, null);
      await again;
    },
  );
  BrowseRepository repo(
    EmbyClient api, {
    BrowseCache? cache,
    Duration spacing = Duration.zero,
  }) => BrowseRepository(
    api,
    cache ?? BrowseCache(prefs),
    BrowsePreferences(prefs),
    now: () => now,
    spacing: spacing,
  );
  EmbyClient api(Future<http.Response> Function(http.Request) f) =>
      EmbyClient(client: MockClient(f))..session = syntheticSession();
  ItemPage one(String id) => ItemPage([
    MediaItem({'Id': id, 'Name': '合成影片', 'Type': 'Movie'}),
  ], 1);

  test(
    'fresh pages survive repository restart without network; fifteen minutes expires',
    () async {
      var calls = 0;
      final client = api((_) async {
        calls++;
        return response('{"Items":[{"Id":"a"}],"TotalRecordCount":1}', 200);
      });
      final first = repo(client);
      expect((await first.items()).items.single.id, 'a');
      await first.items();
      final restarted = repo(client);
      await restarted.items();
      expect(calls, 1);
      now = now.add(const Duration(minutes: 15));
      await restarted.items();
      expect(calls, 2);
      client.close();
    },
  );
  test(
    'cache is account and server scoped, never contains media routes or credentials',
    () async {
      final client = api((_) async => response('{}', 200));
      final repository = repo(client);
      final page = ItemPage([
        MediaItem({
          'Id': 'a',
          'Name': 'Title',
          'AccessToken': 'secret-value',
          'Path': '/nas/secret',
          'MediaSources': [
            {
              'Id': 'source',
              'Name': '1080p',
              'Path': 'https://media.invalid/token',
              'DirectStreamUrl': 'signed-url',
              'RequiredHttpHeaders': {'Authorization': 'secret'},
            },
          ],
          'UserData': {'PlaybackPositionTicks': 200, 'Played': false},
        }),
      ], 1);
      await repository.read('sample', () async => page);
      final saved = prefs.getString(BrowseCache.storageKey)!;
      for (final secret in [
        'secret-value',
        '/nas/',
        'signed-url',
        'Authorization',
        client.session!.token,
      ]) {
        expect(saved, isNot(contains(secret)));
      }
      expect(repository.peek('sample')!.items.single.resume.inMicroseconds, 20);
      client.session = Session(
        base: Uri.parse('https://other.invalid/emby'),
        userId: 'different',
        token: 'new-token',
        username: 'mock',
        deviceId: 'test',
      );
      expect(repo(client).peek('sample'), isNull);
      await expectLater(
        repository.read('sample', () async => one('bad')),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test(
    'coalesces duplicate requests and serializes different metadata endpoints',
    () async {
      var calls = 0, active = 0, peak = 0;
      final client = api((_) async {
        calls++;
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 8));
        active--;
        return response('{"Items":[],"TotalRecordCount":0}', 200);
      });
      final repository = repo(client);
      await Future.wait([
        repository.items(),
        repository.items(),
        repository.items(parent: 'second'),
        repository.resume(),
      ]);
      expect(calls, 3);
      expect(peak, 1);
    },
  );
  test(
    'cooldown prevents request storms and preserves last good cache on 503',
    () async {
      var calls = 0, fail = false;
      final client = api((_) async {
        calls++;
        return fail
            ? response('{}', 503)
            : response('{"Items":[{"Id":"a"}],"TotalRecordCount":1}', 200);
      });
      final repository = repo(client);
      await repository.items();
      now = now.add(const Duration(minutes: 15));
      fail = true;
      await expectLater(repository.items(), throwsA(isA<AppFailure>()));
      for (var i = 0; i < 8; i++) {
        await expectLater(
          repository.items(parent: 'new-$i'),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(calls, 2);
      expect(
        repository
            .peek(BrowseRepository.browseKey(null, '', 0, '', null, false))!
            .items
            .single
            .id,
        'a',
      );
      now = now.add(const Duration(seconds: 31));
      fail = false;
      await repository.items();
      expect(calls, 3);
    },
  );
  test(
    'pausing cancels in-flight and queued browsing; activation permits new work',
    () async {
      var calls = 0;
      final release = Completer<void>();
      final client = api((_) async {
        calls++;
        if (calls == 1) await release.future;
        return response('{"Items":[],"TotalRecordCount":0}', 200);
      });
      final repository = repo(client);
      final running = repository.items();
      final runningCancelled = expectLater(running, throwsA(isA<AppFailure>()));
      await Future<void>.delayed(Duration.zero);
      final queued = repository.items(parent: 'queued');
      final expectation = expectLater(queued, throwsA(isA<AppFailure>()));
      repository.suspend();
      release.complete();
      await runningCancelled;
      await expectation;
      expect(calls, 1);
      repository.activate();
      await repository.items(parent: 'queued');
      expect(calls, 2);
    },
  );
  test(
    'cache LRU and byte limits apply without deleting playback/account preferences',
    () async {
      await prefs.setString('yingyu.tracks.v1', 'keep-tracks');
      await prefs.setString('yingyu.session.v1', 'keep-account');
      final cache = BrowseCache(prefs, maxEntries: 2, maxBytes: 500);
      await cache.put('a', one('a'), now);
      await cache.put('b', one('b'), now);
      cache.get('a');
      await cache.put('c', one('c'), now);
      expect(cache.get('b'), isNull);
      expect(cache.get('a'), isNotNull);
      await cache.put(
        'large',
        ItemPage([
          MediaItem({'Name': 'x' * 2000}),
        ], 1),
        now,
      );
      expect(
        utf8.encode(prefs.getString(BrowseCache.storageKey)!).length,
        lessThanOrEqualTo(500),
      );
      await cache.clear();
      expect(prefs.getString('yingyu.tracks.v1'), 'keep-tracks');
      expect(prefs.getString('yingyu.session.v1'), 'keep-account');
    },
  );
  test('corrupt metadata cache is optional and does not block login', () async {
    await prefs.setString(BrowseCache.storageKey, '[broken');
    expect(BrowseCache(prefs).records, isEmpty);
  });
  test(
    'flat catalogue uses server order and pagination, optional sorting only on explicit choice',
    () async {
      final queries = <Map<String, String>>[];
      final client = api((request) async {
        queries.add(request.url.queryParameters);
        return response('{"Items":[]}', 200);
      });
      await client.browseItems(parent: 'anime', start: 48);
      expect(queries.single['ParentId'], 'anime');
      expect(queries.single['Recursive'], 'true');
      expect(queries.single['GroupItemsIntoCollections'], 'false');
      expect(queries.single['IncludeItemTypes'], 'Movie,Series,Video');
      expect(queries.single.containsKey('SortBy'), false);
      await client.browseItems(sort: 'DateCreated', played: false);
      expect(queries.last['SortOrder'], 'Descending');
      expect(queries.last['IsPlayed'], 'false');
      await client.resumeItems(start: 48, limit: 48);
      expect(queries.last['StartIndex'], '48');
      expect(queries.last['Limit'], '48');
    },
  );
  test(
    'persisted homepage renders cached sections but checks fresh Resume once per entry',
    () async {
      var calls = 0, resumes = 0, minute = 1;
      final client = api((request) async {
        calls++;
        if (request.url.path.endsWith('/Views')) {
          return response(
            '{"Items":[{"Id":"z","Name":"动漫"},{"Id":"a","Name":"电影"}]}',
            200,
          );
        }
        if (request.url.path.endsWith('/Latest')) {
          return response('[{"Id":"movie","Name":"片"}]', 200);
        }
        resumes++;
        return response(
          jsonEncode({
            'Items': [
              {
                'Id': 'resume',
                'Type': 'Movie',
                'UserData': {'PlaybackPositionTicks': minute * 600000000},
              },
            ],
          }),
          200,
        );
      });
      final store = AppStore(prefs);
      final first = HomeFeed(client, store, browse: repo(client));
      await first.refresh();
      expect(calls, 4);
      expect(resumes, 1);
      first.dispose();
      minute = 2;
      final second = HomeFeed(client, store, browse: repo(client));
      expect(second.sections.map((s) => s.library.id), ['z', 'a']);
      expect(second.resume.single.id, 'resume');
      await second.refresh();
      expect(second.resume.single.resume.inMinutes, 2);
      expect(
        calls,
        5,
        reason:
            'Only Resume is refreshed; views and latest sections still use their fresh caches.',
      );
      expect(resumes, 2);
      second.dispose();
      store.dispose();
    },
  );
  test('display cache never replaces fresh playback detail', () async {
    var minute = 1, calls = 0;
    final client = api((_) async {
      calls++;
      return response(
        jsonEncode({
          'Id': 'movie',
          'Type': 'Movie',
          'UserData': {'PlaybackPositionTicks': minute * 600000000},
        }),
        200,
      );
    });
    final repository = repo(client);
    expect((await repository.detail('movie')).resume.inMinutes, 1);
    minute = 8;
    expect((await repository.detail('movie')).resume.inMinutes, 1);
    expect((await client.detail('movie')).resume.inMinutes, 8);
    expect(calls, 2);
  });
  test(
    'pinyin index includes simplified, traditional, latin and numeric titles',
    () {
      expect(titleLetter('阿丽塔'), 'A');
      expect(titleLetter('動畫'), 'D');
      expect(titleLetter('Zebra'), 'Z');
      expect(titleLetter('2001太空漫游'), '#');
      final item = MediaItem({'Id': 'm', 'Name': '天空之城'});
      expect(matchesTitle(item, 'tkzc'), true);
      expect(matchesTitle(item, 'tiankong'), true);
      final sorted = alphabetize([
        item,
        MediaItem({'Id': 'a', 'Name': '阿丽塔'}),
        MediaItem({'Id': 'a', 'Name': 'duplicate'}),
        MediaItem({'Id': '1', 'Name': '2001'}),
      ]);
      expect(sorted.map((i) => i.id), ['1', 'a', 'm']);
    },
  );
  test(
    'poster service rejects no-longer-visible work and backs off on server overload',
    () async {
      var calls = 0, visible = true;
      final service = PosterFileService(
        client: MockClient((_) async {
          calls++;
          return response('', 503);
        }),
        visible: (_) => visible,
        now: () => now,
        spacing: Duration.zero,
      );
      expect(service.concurrentFetches, 2);
      visible = false;
      await expectLater(
        service.get('https://mock.invalid/a'),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 0);
      visible = true;
      final failed = await service.get('https://mock.invalid/a');
      expect(failed.statusCode, 503);
      await expectLater(
        service.get('https://mock.invalid/b'),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
      now = now.add(const Duration(seconds: 31));
      await service.get('https://mock.invalid/c');
      expect(calls, 2);
    },
  );
  test(
    'tagged images remain fresh on disk and request starts are paced',
    () async {
      final watch = Stopwatch()..start();
      final starts = <int>[];
      final service = PosterFileService(
        client: MockClient((_) async {
          starts.add(watch.elapsedMilliseconds);
          return http.Response(
            'bytes',
            200,
            headers: {'cache-control': 'no-cache'},
          );
        }),
        visible: (_) => true,
        spacing: const Duration(milliseconds: 60),
      );
      final image = await service.get('https://mock.invalid/a?tag=version');
      expect(
        image.validTill.difference(DateTime.now()).inDays,
        greaterThanOrEqualTo(29),
      );
      await service.get('https://mock.invalid/b');
      expect(starts[1] - starts[0], greaterThanOrEqualTo(50));
    },
  );
  test('independent image callers share at most two download slots', () async {
    var active = 0, peak = 0, calls = 0;
    final first = Completer<void>();
    final service = PosterFileService(
      client: MockClient((_) async {
        calls++;
        active++;
        if (active > peak) peak = active;
        await first.future;
        active--;
        return response('image', 200);
      }),
      visible: (_) => true,
      spacing: Duration.zero,
    );
    final wall = service.get('https://mock.invalid/wall');
    final detail = service.get('https://mock.invalid/detail');
    final third = service.get('https://mock.invalid/third');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    first.complete();
    await Future.wait([wall, detail, third]);
    expect(calls, 3);
    expect(peak, 2);
  });
}
