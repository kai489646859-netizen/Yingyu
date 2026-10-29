// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/progress.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, playbackData, response;
import 'playback_test.dart' show FakeBackend;

class _PendingSeekBackend extends FakeBackend {
  final entered = Completer<void>(), release = Completer<void>();
  bool waiting = true;
  @override
  Future<void> seek(Duration at) async {
    if (!waiting) return super.seek(at);
    entered.complete();
    await release.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final exitMs in [0, 1543, 2500]) {
    test(
      'explicit restart at $exitMs ms survives a stopped server zero',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        var serverMs = 1311018, supplements = 0;
        MediaItem detail() => MediaItem({
          'Id': 'movie',
          'Type': 'Movie',
          'RunTimeTicks': 91322570000,
          'UserData': {
            'PlaybackPositionTicks': serverMs * 10000,
            'Played': false,
            'PlayCount': 1,
            'IsFavorite': false,
          },
        });
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (request.url.path.contains('Sessions/Playing')) {
              if (request.url.path.endsWith('/Stopped')) serverMs = 0;
              return response('', 204);
            }
            if (request.url.path.endsWith('/UserData') &&
                request.method == 'POST') {
              supplements++;
              return response('{}', 200);
            }
            if (request.url.path.endsWith('/Resume')) {
              return response('{"Items":[],"TotalRecordCount":0}', 200);
            }
            return response(jsonEncode(detail().data), 200);
          }),
        )..session = syntheticSession();
        final backend = FakeBackend()..gate.complete();
        final original = detail();
        final player = PlaybackSession(
          api: api,
          store: store,
          item: original,
          backend: backend,
        );
        final feed = HomeFeed(api, store);
        addTearDown(() async {
          await player.close();
          feed.dispose();
          player.dispose();
          api.close();
          store.log.dispose();
          store.dispose();
        });
        await player.open();
        await player.seek(Duration.zero, source: SeekSource.slider);
        backend.snapshot = PlaybackSnapshot(
          position: Duration(milliseconds: exitMs),
          duration: const Duration(milliseconds: 9132257),
          playing: true,
        );
        backend.updates.add(backend.snapshot);
        await Future<void>.delayed(Duration.zero);
        await player.report('Progress');
        await player.close();
        expect(player.position.inMilliseconds, exitMs);
        expect(player.completed, false);
        if (exitMs == 0) {
          expect(store.localProgress(api.session!, 'movie'), isNull);
          expect(player.syncWarning, isNull);
          expect(supplements, 0);
        } else {
          expect(
            store.localProgress(api.session!, 'movie')?.inMilliseconds,
            exitMs,
          );
          expect(player.syncWarning, contains('尚未返回相同进度'));
          expect(supplements, 1);
        }
        await feed.afterPlayback(original, actualCompleted: player.completed);
        expect(feed.resume, isEmpty);
        await feed.refreshResume(force: true);
        expect(feed.resume, isEmpty);
      },
    );
  }

  for (final waiting in [false, true]) {
    test(
      'last second without EOF survives exit and reopen; pending seek=$waiting',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        var serverMs = 35000;
        MediaItem detail() => MediaItem({
          'Id': 'movie',
          'Type': 'Movie',
          'RunTimeTicks': 6000000000,
          'UserData': {
            'PlaybackPositionTicks': serverMs * 10000,
            'Played': false,
            'PlayCount': 1,
            'IsFavorite': false,
          },
        });
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (request.url.path.contains('Sessions/Playing')) {
              if (request.url.path.endsWith('/Stopped')) {
                serverMs =
                    integer(jsonDecode(request.body)['PositionTicks']) ~/ 10000;
              }
              return response('', 204);
            }
            if (request.url.path.endsWith('/Resume')) {
              return response('{"Items":[],"TotalRecordCount":0}', 200);
            }
            return response(jsonEncode(detail().data), 200);
          }),
        )..session = syntheticSession();
        final backend = waiting ? _PendingSeekBackend() : FakeBackend();
        backend.gate.complete();
        backend.snapshot = const PlaybackSnapshot(
          duration: Duration(minutes: 10),
        );
        final player = PlaybackSession(
          api: api,
          store: store,
          item: detail(),
          backend: backend,
        );
        final feed = HomeFeed(api, store);
        PlaybackSession? next;
        addTearDown(() async {
          if (backend is _PendingSeekBackend && !backend.release.isCompleted) {
            backend.release.complete();
          }
          await player.close();
          await next?.close();
          feed.dispose();
          player.dispose();
          next?.dispose();
          api.close();
          store.log.dispose();
          store.dispose();
        });
        await player.open();
        final moving = player.seek(const Duration(seconds: 599));
        if (backend is _PendingSeekBackend) {
          await backend.entered.future;
          expect(player.seeking, true);
        } else {
          await moving;
        }
        expect(player.position, const Duration(seconds: 599));
        expect(player.completed, false);
        await player.close();
        expect(serverMs, 599000);
        if (backend is _PendingSeekBackend) {
          backend.release.complete();
          await moving;
          expect(player.position, const Duration(seconds: 599));
        }
        await feed.afterPlayback(detail(), actualCompleted: player.completed);
        expect(feed.resume, isEmpty);
        final nextBackend = FakeBackend()..gate.complete();
        next = PlaybackSession(
          api: api,
          store: store,
          item: detail(),
          backend: nextBackend,
        );
        await next.open();
        expect(nextBackend.initial, const Duration(seconds: 599));
        expect(next.completed, false);
      },
    );
  }

  test(
    'checkpoint tolerance keeps the zero boundary distinct in both directions',
    () {
      expect(progressMatches(Duration.zero, Duration.zero), true);
      for (final ms in [1, 1543, 2000]) {
        expect(
          progressMatches(Duration.zero, Duration(milliseconds: ms)),
          false,
        );
        expect(
          progressMatches(Duration(milliseconds: ms), Duration.zero),
          false,
        );
      }
      expect(
        progressMatches(const Duration(seconds: 1), const Duration(seconds: 3)),
        true,
      );
      expect(
        progressMatches(const Duration(seconds: 3), const Duration(seconds: 1)),
        true,
      );
      expect(
        progressMatches(
          const Duration(seconds: 1),
          const Duration(milliseconds: 3001),
        ),
        false,
      );
      expect(
        progressMatches(
          const Duration(seconds: -1),
          const Duration(seconds: 1),
        ),
        false,
      );
      expect(
        progressMatches(
          const Duration(seconds: -1),
          const Duration(seconds: -1),
        ),
        false,
      );
    },
  );

  test(
    'unchanged server preserves short positive and intentional zero; newer server still wins',
    () {
      MediaItem item(int ms, String date) => MediaItem({
        'Id': 'movie',
        'UserData': {
          'PlaybackPositionTicks': ms * 10000,
          'LastPlayedDate': date,
        },
      });
      final zero = item(0, '2026-10-16T00:00:00Z');
      final short = item(1543, '2026-10-16T00:00:00Z');
      expect(
        resolveResume(
          zero,
          const Duration(milliseconds: 1543),
          progressFingerprint(zero),
        ).position,
        const Duration(milliseconds: 1543),
      );
      expect(
        resolveResume(
          short,
          Duration.zero,
          progressFingerprint(short),
        ).position,
        Duration.zero,
      );
      expect(
        resolveResume(
          item(1200, '2026-10-16T00:01:00Z'),
          Duration.zero,
          progressFingerprint(short),
        ).position,
        const Duration(milliseconds: 1200),
      );
    },
  );

  for (final expire in [false, true]) {
    test(
      'account change before close preserves only the old account checkpoint; expired=$expire',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        var reports = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (request.url.path.contains('Sessions/Playing')) {
              reports++;
              return response('', 204);
            }
            return response(
              jsonEncode({
                'Id': 'movie',
                'Type': 'Movie',
                'RunTimeTicks': 6000000000,
                'UserData': {
                  'PlaybackPositionTicks': 350000000,
                  'Played': false,
                  'PlayCount': 1,
                  'IsFavorite': false,
                },
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        final original = api.session!;
        final other = syntheticSession('http://127.0.0.1:10/proxy/emby');
        final backend = FakeBackend()..gate.complete();
        final player = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        addTearDown(() async {
          await player.close();
          player.dispose();
          api.close();
          store.log.dispose();
          store.dispose();
        });
        await player.open();
        await player.report('Progress');
        await player.seek(const Duration(seconds: 42));
        await player.report('Progress');
        backend.snapshot = const PlaybackSnapshot(
          position: Duration(seconds: 45),
          duration: Duration(minutes: 10),
          playing: true,
        );
        backend.updates.add(backend.snapshot);
        await Future<void>.delayed(Duration.zero);
        api.session = expire ? null : other;
        final before = reports;
        await player.close();
        expect(
          store.localProgress(original, 'movie'),
          const Duration(seconds: 45),
        );
        expect(store.localProgress(other, 'movie'), isNull);
        expect(reports, before);
        expect(player.syncWarning, contains('账户已切换'));
      },
    );
  }

  for (final fail in [false, true]) {
    test(
      'real EOF then pending restart ${fail ? 'failure restores completion' : 'exit preserves new zero intent'}',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        var serverMs = 0, completionWrites = 0;
        var played = false;
        MediaItem detail() => MediaItem({
          'Id': 'movie',
          'Type': 'Movie',
          'RunTimeTicks': 6000000000,
          'UserData': {
            'PlaybackPositionTicks': serverMs * 10000,
            'Played': played,
            'PlayCount': 1,
            'IsFavorite': false,
          },
        });
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (request.url.path.contains('Sessions/Playing')) {
              serverMs =
                  integer(jsonDecode(request.body)['PositionTicks']) ~/ 10000;
              return response('', 204);
            }
            if (request.url.path.contains('PlayedItems/')) {
              played = true;
              serverMs = 0;
              completionWrites++;
              return response('{}', 200);
            }
            if (request.url.path.endsWith('/Resume')) {
              return response('{"Items":[],"TotalRecordCount":0}', 200);
            }
            return response(jsonEncode(detail().data), 200);
          }),
        )..session = syntheticSession();
        final backend = _PendingSeekBackend()..waiting = false;
        backend.gate.complete();
        backend.snapshot = const PlaybackSnapshot(
          duration: Duration(minutes: 10),
        );
        final player = PlaybackSession(
          api: api,
          store: store,
          item: detail(),
          backend: backend,
        );
        final feed = HomeFeed(api, store);
        addTearDown(() async {
          if (!backend.release.isCompleted) backend.release.complete();
          await player.close();
          feed.dispose();
          player.dispose();
          api.close();
          store.log.dispose();
          store.dispose();
        });
        await player.open();
        await player.seek(const Duration(seconds: 599));
        backend.snapshot = const PlaybackSnapshot(
          position: Duration(minutes: 10),
          duration: Duration(minutes: 10),
          completed: true,
        );
        backend.updates.add(backend.snapshot);
        await Future<void>.delayed(Duration.zero);
        await player.report('Progress');
        expect(player.completed, true);
        expect(completionWrites, 1);
        backend.waiting = true;
        final moving = player.seek(Duration.zero, source: SeekSource.slider);
        await backend.entered.future;
        expect(player.completed, false);
        if (fail) {
          backend.release.completeError(
            const AppFailure('synthetic seek failure'),
          );
          await expectLater(moving, throwsA(isA<AppFailure>()));
          expect(player.completed, true);
          expect(player.position, const Duration(minutes: 10));
          expect(store.restartObserved(api.session!, detail()), false);
        } else {
          await player.close();
          expect(player.completed, false);
          expect(serverMs, 0);
          await feed.afterPlayback(detail(), actualCompleted: player.completed);
          expect(feed.resume, isEmpty);
          expect(store.restartObserved(api.session!, detail()), true);
          backend.release.complete();
          await moving;
          expect(player.completed, false);
        }
        expect(completionWrites, 1);
      },
    );
  }

  test(
    'explicit from-beginning entry keeps a zero row without a slider command',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      var serverMs = 35000;
      MediaItem detail() => MediaItem({
        'Id': 'movie',
        'Type': 'Movie',
        'RunTimeTicks': 6000000000,
        'UserData': {
          'PlaybackPositionTicks': serverMs * 10000,
          'Played': false,
          'PlayCount': 1,
          'IsFavorite': false,
        },
      });
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            serverMs =
                integer(jsonDecode(request.body)['PositionTicks']) ~/ 10000;
            return response('', 204);
          }
          if (request.url.path.endsWith('/Resume')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          return response(jsonEncode(detail().data), 200);
        }),
      )..session = syntheticSession();
      final backend = FakeBackend()..gate.complete();
      final original = detail();
      final player = PlaybackSession(
        api: api,
        store: store,
        item: original,
        backend: backend,
      );
      final feed = HomeFeed(api, store);
      addTearDown(() async {
        await player.close();
        feed.dispose();
        player.dispose();
        api.close();
        store.log.dispose();
        store.dispose();
      });
      await player.open(fromBeginning: true);
      expect(backend.initial, Duration.zero);
      await player.close();
      await feed.afterPlayback(original, actualCompleted: false);
      expect(feed.resume, isEmpty);
      expect(store.restartObserved(api.session!, detail()), true);
    },
  );

  test(
    'unaccepted zero keeps its display across the complete stopped flow and restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final original = MediaItem({
        'Id': 'movie',
        'Type': 'Movie',
        'RunTimeTicks': 6000000000,
        'UserData': {
          'PlaybackPositionTicks': 1200000000,
          'Played': false,
          'PlayCount': 1,
          'IsFavorite': false,
        },
      });
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing') ||
              request.url.path.endsWith('/UserData')) {
            return response('', 204);
          }
          if (request.url.path.endsWith('/Resume')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          return response(jsonEncode(original.data), 200);
        }),
      )..session = syntheticSession();
      final backend = FakeBackend()..gate.complete();
      final player = PlaybackSession(
        api: api,
        store: store,
        item: original,
        backend: backend,
      );
      final feed = HomeFeed(api, store);
      HomeFeed? reopened;
      addTearDown(() async {
        await player.close();
        feed.dispose();
        reopened?.dispose();
        player.dispose();
        api.close();
        store.log.dispose();
        store.dispose();
      });
      await player.open();
      await player.seek(Duration.zero, source: SeekSource.slider);
      await player.close();
      expect(store.localProgress(api.session!, 'movie'), Duration.zero);
      expect(player.syncWarning, contains('尚未返回相同进度'));
      await feed.afterPlayback(original, actualCompleted: false);
      expect(feed.resume, isEmpty);
      await feed.refreshResume(force: true);
      expect(feed.resume, isEmpty);
      final restartedFeed = HomeFeed(api, store);
      reopened = restartedFeed;
      expect(restartedFeed.resume, isEmpty);
      await restartedFeed.refreshResume(force: true);
      expect(restartedFeed.resume, isEmpty);
    },
  );

  test(
    'real EOF on an already-played server restarts even if stopped retains a positive tail',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      var serverMs = 35000;
      MediaItem detail() => MediaItem({
        'Id': 'movie',
        'Type': 'Movie',
        'RunTimeTicks': 6000000000,
        'UserData': {
          'PlaybackPositionTicks': serverMs * 10000,
          'Played': true,
          'PlayCount': 1,
          'IsFavorite': false,
        },
      });
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            serverMs =
                integer(jsonDecode(request.body)['PositionTicks']) ~/ 10000;
            return response('', 204);
          }
          if (request.url.path.endsWith('/Resume')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          return response(jsonEncode(detail().data), 200);
        }),
      )..session = syntheticSession();
      final backend = FakeBackend()..gate.complete();
      final player = PlaybackSession(
        api: api,
        store: store,
        item: detail(),
        backend: backend,
      );
      PlaybackSession? next;
      addTearDown(() async {
        await player.close();
        await next?.close();
        player.dispose();
        next?.dispose();
        api.close();
        store.log.dispose();
        store.dispose();
      });
      await player.open();
      await player.seek(const Duration(seconds: 599));
      backend.snapshot = const PlaybackSnapshot(
        position: Duration(minutes: 10),
        duration: Duration(minutes: 10),
        completed: true,
      );
      backend.updates.add(backend.snapshot);
      await Future<void>.delayed(Duration.zero);
      await player.report('Progress');
      await player.close();
      expect(player.completed, true);
      expect(serverMs, 600000);
      expect(store.localProgress(api.session!, 'movie'), Duration.zero);
      expect(player.syncWarning, contains('Emby 已确认看完，但尚未返回零位置'));
      final nextBackend = FakeBackend()..gate.complete();
      final reopened = PlaybackSession(
        api: api,
        store: store,
        item: detail(),
        backend: nextBackend,
      );
      next = reopened;
      await reopened.open();
      expect(nextBackend.initial, Duration.zero);
    },
  );
}
