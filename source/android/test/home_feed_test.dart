import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem entry(
  String id, {
  String? series,
  int seconds = 60,
  String date = '2026-10-07T08:00:00Z',
  bool played = false,
}) => MediaItem({
  'Id': id,
  'Name': '合成 $id',
  'Type': series == null ? 'Movie' : 'Episode',
  'SeriesId': ?series,
  'RunTimeTicks': 36000000000,
  'UserData': {
    'PlaybackPositionTicks': seconds * 10000000,
    'LastPlayedDate': date,
    'Played': played,
    'PlayCount': 1,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
  });
  EmbyClient client(Future<http.Response> Function(http.Request) run) =>
      EmbyClient(client: MockClient(run))..session = syntheticSession();

  test(
    'homepage endpoints follow PC limits and preserve server order without sort overrides',
    () async {
      final calls = <http.Request>[];
      final api = client((request) async {
        calls.add(request);
        final values = [entry('z').data, entry('a').data];
        return response(
          jsonEncode(
            request.url.path.endsWith('Latest')
                ? values
                : {'Items': values, 'TotalRecordCount': 2},
          ),
          200,
        );
      });
      expect((await api.latestItems('server-first')).map((e) => e.id), [
        'z',
        'a',
      ]);
      expect((await api.resumeItems()).items.map((e) => e.id), ['z', 'a']);
      expect(calls.first.url.queryParameters['ParentId'], 'server-first');
      expect(
        calls.first.url.queryParameters['IncludeItemTypes'],
        'Movie,Episode',
      );
      expect(calls.last.url.queryParameters['MediaTypes'], 'Video');
      for (final request in calls) {
        expect(request.url.queryParameters['Limit'], '18');
        expect(request.url.queryParameters['EnableUserData'], 'true');
        expect(
          request.url.queryParameters.keys,
          isNot(
            contains(anyOf('SortBy', 'SortOrder', 'GroupItems', 'IsPlayed')),
          ),
        );
        expect(
          request.headers['X-Emby-Token'] ?? request.headers['x-emby-token'],
          isNotEmpty,
        );
        expect(request.followRedirects, false);
      }
    },
  );

  for (final invalid in ['', '{}', '[1]', 'null']) {
    test(
      'Latest rejects invalid successful payload $invalid instead of false empty success',
      () async {
        final api = client((_) async => response(invalid, 200));
        await expectLater(
          api.latestItems('movies'),
          throwsA(isA<AppFailure>()),
        );
      },
    );
  }
  test('Latest accepts a genuinely empty JSON array', () async {
    final api = client((_) async => response('[]', 200));
    expect(await api.latestItems('movies'), isEmpty);
  });

  test(
    'home orders sections by Views, not completion, including resume in the two-request ceiling',
    () async {
      var active = 0, peak = 0;
      final starts = <String>[];
      final api = client((request) async {
        final path = request.url.path;
        if (path.endsWith('/Views')) {
          return response(
            jsonEncode({
              'Items': [
                {'Id': 'animation', 'Name': '动漫'},
                {'Id': 'films', 'Name': '电影'},
                {'Id': 'series', 'Name': '剧集'},
              ],
            }),
            200,
          );
        }
        active++;
        if (active > peak) peak = active;
        final name = request.url.queryParameters['ParentId'] ?? 'resume';
        starts.add(name);
        await Future<void>.delayed(
          Duration(milliseconds: name == 'animation' ? 40 : 8),
        );
        active--;
        return response(
          jsonEncode(
            path.endsWith('/Resume')
                ? {
                    'Items': [
                      entry('episode-a', series: 'S').data,
                      entry('episode-b', series: 's').data,
                    ],
                  }
                : [entry('$name-z').data, entry('$name-a').data],
          ),
          200,
        );
      });
      final feed = HomeFeed(api, store);
      await feed.refresh();
      expect(peak, 2);
      expect(starts.first, 'resume');
      expect(feed.sections.map((s) => s.library.id), [
        'animation',
        'films',
        'series',
      ]);
      expect(feed.sections.first.items.map((e) => e.id), [
        'animation-z',
        'animation-a',
      ]);
      expect(feed.resume.map((e) => e.id), ['episode-a']);
      expect(feed.loading, false);
      feed.dispose();
    },
  );

  test(
    'failed rows retain previous content and report errors, with a working retry',
    () async {
      var fail = false;
      final api = client((r) async {
        if (fail && !r.url.path.endsWith('/Views')) return response('{}', 503);
        if (r.url.path.endsWith('/Views')) {
          return response('{"Items":[{"Id":"films","Name":"电影"}]}', 200);
        }
        if (r.url.path.endsWith('/Resume')) {
          return response(
            jsonEncode({
              'Items': [entry('recent').data],
            }),
            200,
          );
        }
        return response(jsonEncode([entry('latest').data]), 200);
      });
      final feed = HomeFeed(api, store);
      await feed.refresh();
      fail = true;
      await feed.refresh();
      expect(feed.resume.single.id, 'recent');
      expect(feed.sections.single.items.single.id, 'latest');
      expect(feed.resumeError, isNotNull);
      expect(feed.sections.single.error, isNotNull);
      fail = false;
      await feed.loadSection(feed.sections.single, feed.generation);
      await feed.refreshResume(force: true);
      expect(feed.sections.single.error, isNull);
      expect(feed.resumeError, isNull);
      feed.dispose();
    },
  );

  test(
    'series merge keeps first exact episode, server sequence and at most 18 titles',
    () {
      final a = entry('e5', series: 'SERIES', seconds: 300);
      final list = collapseResume([
        a,
        entry('e4', series: 'series', seconds: 90),
        ...List.generate(30, (i) => entry('movie-$i')),
      ]);
      expect(list.length, 18);
      expect(identical(list.first, a), true);
      expect(list.first.resume, const Duration(seconds: 300));
      expect(list[1].id, 'movie-0');
      expect(list.last.id, 'movie-16');
    },
  );

  test(
    'pending storage survives while Resume shows current server and backwards progress',
    () async {
      var server = entry('movie', seconds: 100);
      final api = client(
        (r) async => response(
          jsonEncode(
            r.url.path.endsWith('/Resume')
                ? {
                    'Items': [server.data],
                  }
                : server.data,
          ),
          200,
        ),
      );
      final feed = HomeFeed(api, store);
      await store.saveProgress(
        api.session!,
        'movie',
        const Duration(seconds: 900),
        serverBaseline: server,
      );
      final before = {
        for (final key in store.prefs.getKeys()) key: store.prefs.get(key),
      };
      await feed.afterPlayback(server);
      expect(feed.resume.single.resume, server.resume);
      expect(
        store.localProgress(api.session!, server.id),
        const Duration(seconds: 900),
      );
      server = entry('movie', seconds: 50, date: '2026-10-07T09:00:00Z');
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 50));
      for (final key in before.keys) {
        expect(store.prefs.get(key), before[key]);
      }
      feed.dispose();
    },
  );

  test(
    'confirmed detail metadata cannot replace a server Resume checkpoint',
    () async {
      var detail = entry('movie', seconds: 300, date: '2026-10-07T09:00:00Z');
      var resume = entry('movie', seconds: 100);
      final api = client(
        (r) async => response(
          jsonEncode(
            r.url.path.endsWith('/Resume')
                ? {
                    'Items': [resume.data],
                  }
                : detail.data,
          ),
          200,
        ),
      );
      final feed = HomeFeed(api, store);
      await feed.afterPlayback(detail);
      expect(feed.resume.single.resume, resume.resume);
      resume = entry('movie', seconds: 40, date: '2026-10-07T10:00:00Z');
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 40));
      detail = entry(
        'movie',
        seconds: 0,
        played: true,
        date: '2026-10-07T11:00:00Z',
      );
      await feed.afterPlayback(detail);
      expect(feed.resume.single.id, 'movie');
      expect(object(feed.resume.single.data['UserData'])['Played'], false);
      expect(feed.resume.single.resume, resume.resume);
      resume = entry('movie', seconds: 25, date: '2026-10-07T12:00:00Z');
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 25));
      feed.dispose();
    },
  );

  test(
    'pending zero stays durable while the server checkpoint stays visible',
    () async {
      var server = entry('movie', seconds: 100);
      final api = client(
        (r) async => response(
          jsonEncode(
            r.url.path.endsWith('/Resume')
                ? {
                    'Items': [server.data],
                  }
                : server.data,
          ),
          200,
        ),
      );
      final feed = HomeFeed(api, store);
      await store.saveProgress(
        api.session!,
        'movie',
        Duration.zero,
        serverBaseline: server,
      );
      await feed.afterPlayback(server);
      expect(feed.resume.single.resume, server.resume);
      expect(store.localProgress(api.session!, server.id), Duration.zero);
      server = entry('movie', seconds: 20, date: '2026-10-07T12:00:00Z');
      await feed.refreshResume(force: true);
      expect(feed.resume.single.resume, const Duration(seconds: 20));
      feed.dispose();
    },
  );

  test(
    'bounded account cache stores display metadata, no paths, sources, or account credentials',
    () async {
      var server = entry('movie');
      final api = client(
        (r) async => response(
          jsonEncode(
            r.url.path.endsWith('/Resume')
                ? {'Items': []}
                : {
                    ...server.data,
                    'Path': 'https://private.invalid/secret',
                    'MediaSources': [
                      {'Path': 'signed-secret'},
                    ],
                    'AccessToken': 'secret-token',
                  },
          ),
          200,
        ),
      );
      final feed = HomeFeed(api, store);
      for (var i = 0; i < 20; i++) {
        server = entry('movie-$i');
        await feed.afterPlayback(server);
      }
      final cache = store.prefs.getString(feed.cacheKey)!;
      expect((jsonDecode(cache)['items'] as List).length, 18);
      expect(cache, isNot(contains('secret')));
      expect(cache, isNot(contains(api.session!.token)));
      final reopened = HomeFeed(api, store);
      expect(reopened.cachedItems.last.id, 'movie-19');
      expect(reopened.resume, isEmpty);
      final otherAccount = Session(
        base: api.session!.base,
        userId: 'other',
        token: 'fake-other',
        username: 'other',
        deviceId: 'fake-device',
        serverId: 'server',
      );
      api.session = otherAccount;
      final other = HomeFeed(api, store);
      expect(other.resume, isEmpty);
      expect(other.cacheKey, isNot(feed.cacheKey));
      feed.dispose();
      reopened.dispose();
      other.dispose();
    },
  );

  test(
    'resume refresh is throttled, explicit retry bypasses only time throttle',
    () async {
      var calls = 0;
      final api = client((_) async {
        calls++;
        return response('{"Items":[]}', 200);
      });
      final feed = HomeFeed(api, store);
      await feed.refreshResume();
      await feed.refreshResume();
      expect(calls, 1);
      await feed.refreshResume(force: true);
      expect(calls, 2);
      feed.suspend();
      await feed.refreshResume(force: true);
      expect(calls, 2);
      feed.dispose();
    },
  );

  test(
    'playing suspends queued home metadata, stale requests never update results',
    () async {
      final gate = Completer<void>();
      final started = Completer<void>();
      var calls = 0;
      final api = client((r) async {
        if (r.url.path.endsWith('/Views')) {
          return response('{"Items":[{"Id":"a"},{"Id":"b"},{"Id":"c"}]}', 200);
        }
        calls++;
        if (calls == 2) started.complete();
        await gate.future;
        return response(
          r.url.path.endsWith('/Resume') ? '{"Items":[]}' : '[{"Id":"late"}]',
          200,
        );
      });
      final feed = HomeFeed(api, store);
      final refresh = feed.refresh();
      await started.future;
      final retry = feed.loadSection(feed.sections.last, feed.generation);
      feed.suspend();
      gate.complete();
      await Future.wait([refresh, retry]);
      expect(calls, 2);
      expect(feed.sections.every((s) => s.items.isEmpty), true);
      expect(feed.resume, isEmpty);
      expect(feed.sections.every((s) => !s.loading), true);
      feed.activate();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(feed.sections.every((s) => s.items.single.id == 'late'), true);
      expect(feed.loading, false);
      feed.dispose();
    },
  );

  test('account change invalidates old homepage responses', () async {
    final gate = Completer<void>();
    final started = Completer<void>();
    final api = client((_) async {
      started.complete();
      await gate.future;
      return response('{"Items":[{"Id":"private-old-item"}]}', 200);
    });
    final feed = HomeFeed(api, store);
    final pending = feed.refreshResume();
    await started.future;
    api.session = null;
    gate.complete();
    await pending;
    expect(feed.resume, isEmpty);
    feed.dispose();
  });

  testWidgets(
    'continue watching preserves exact episode callback and progress; artwork never changes play ID',
    (tester) async {
      var calls = 0;
      final api = client((_) async {
        calls++;
        throw StateError('unexpected request');
      });
      final feed = HomeFeed(api, store);
      final target = entry('episode-current', series: 'series');
      feed.resume = [target];
      MediaItem? played;
      MediaItem? detailed;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: ContinueWatching(
              feed: feed,
              active: false,
              onPlay: (item) async {
                played = item;
              },
              onDetail: (item) async => detailed = item,
            ),
          ),
        ),
      );
      await tester.tapAt(
        tester.getTopLeft(
              find.byKey(const ValueKey('resume-episode-current')),
            ) +
            const Offset(10, 10),
      );
      expect(identical(detailed, target), true);
      expect(played, null);
      detailed = null;
      await tester.tap(
        find.byKey(const ValueKey('resume-play-episode-current')),
      );
      expect(detailed, null);
      expect(identical(played, target), true);
      expect(played!.resume, const Duration(seconds: 60));
      final widget = ContinueWatching(
        feed: feed,
        active: false,
        onPlay: (_) async {},
        onDetail: (_) async {},
      );
      final artwork = widget.artwork(
        MediaItem({
          ...target.data,
          'ParentThumbItemId': 'parent-art',
          'ParentThumbImageTag': 'tag',
        }),
      );
      expect(
        Uri.parse(artwork!).path,
        endsWith('/Items/parent-art/Images/Thumb'),
      );
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 600));
      feed.dispose();
    },
  );
}
