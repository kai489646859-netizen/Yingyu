import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, playbackData, response;
import 'playback_test.dart' show FakeBackend;

class _Backend extends FakeBackend {
  final seekEntered = Completer<void>(), seekRelease = Completer<void>();
  final playEntered = Completer<void>(), playRelease = Completer<void>();
  bool holdSeek = false, failSeek = false, holdPlay = false;
  @override
  Future<void> seek(Duration at) async {
    if (holdSeek) {
      seekEntered.complete();
      await seekRelease.future;
      if (failSeek) throw const AppFailure('synthetic seek failure');
    }
    if (!disposed) await super.seek(at);
  }

  @override
  Future<void> play() async {
    if (holdPlay) {
      playEntered.complete();
      await playRelease.future;
    }
    await super.play();
  }
}

class _Fixture {
  _Fixture._(this.store) {
    api = EmbyClient(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (path.contains('Sessions/Playing')) {
          reports.add(path);
          if (offline) return response('{}', 503);
          serverMs =
              integer(jsonDecode(request.body)['PositionTicks']) ~/ 10000;
          return response('', 204);
        }
        if (path.contains('PlayedItems/')) {
          return response('{}', 503);
        }
        return response(
          jsonEncode({
            'Id': 'movie',
            'Type': 'Movie',
            'RunTimeTicks': 6000000000,
            'UserData': {
              'PlaybackPositionTicks': serverMs * 10000,
              'Played': false,
              'PlayCount': 1,
              'IsFavorite': false,
              'LastPlayedDate': '2020-01-01T00:00:00Z',
            },
          }),
          200,
        );
      }),
    )..session = syntheticSession();
    backend.gate.complete();
    backend.snapshot = const PlaybackSnapshot(duration: Duration(minutes: 10));
    player = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
  }
  final AppStore store;
  late final EmbyClient api;
  final backend = _Backend();
  late final PlaybackSession player;
  final reports = <String>[];
  int serverMs = 120000;
  bool offline = false;
  static Future<_Fixture> create() async {
    SharedPreferences.setMockInitialValues({});
    return _Fixture._(AppStore(await SharedPreferences.getInstance()));
  }

  Future<void> pendingCompletion() async {
    await player.open();
    await player.report('Progress');
    offline = true;
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
    expect(store.completions.pending(player.account, 'movie'), true);
    expect(store.completions.superseded(player.account, 'movie'), false);
  }

  Future<void> dispose() async {
    if (!backend.seekRelease.isCompleted) backend.seekRelease.complete();
    if (!backend.playRelease.isCompleted) backend.playRelease.complete();
    await player.close();
    player.dispose();
    api.close();
    store.log.dispose();
    store.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final outcome in ['success', 'failure', 'close']) {
    test(
      'pending seek $outcome preserves or supersedes the real EOF at the correct boundary',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        await fixture.pendingCompletion();
        fixture.backend
          ..holdSeek = true
          ..failSeek = outcome == 'failure';
        final target = outcome == 'success'
            ? const Duration(seconds: 45)
            : Duration.zero;
        final moving = fixture.player.seek(target, source: SeekSource.slider);
        final failed = outcome == 'failure'
            ? expectLater(moving, throwsA(isA<AppFailure>()))
            : null;
        await fixture.backend.seekEntered.future;
        final before = fixture.reports.length;
        await fixture.player.report('Progress');
        expect(fixture.reports.length, before);
        expect(
          fixture.store.completions.superseded(fixture.player.account, 'movie'),
          false,
        );
        expect(
          fixture.store.localProgress(fixture.player.account, 'movie'),
          Duration.zero,
        );
        if (outcome == 'close') await fixture.player.close();
        fixture.backend.seekRelease.complete();
        if (failed != null) {
          await failed;
          expect(fixture.player.completed, true);
          expect(
            fixture.store.completions.pending(fixture.player.account, 'movie'),
            true,
          );
          expect(
            fixture.store.completions.superseded(
              fixture.player.account,
              'movie',
            ),
            false,
          );
        } else {
          await moving;
          if (outcome == 'success') await fixture.player.report('Progress');
          expect(fixture.player.completed, false);
          expect(
            fixture.store.completions.superseded(
              fixture.player.account,
              'movie',
            ),
            true,
          );
          expect(
            fixture.store.localProgress(fixture.player.account, 'movie'),
            target,
          );
        }
      },
    );
  }

  test(
    'a seek during opening retains Started but defers checkpoint writes until settled',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      fixture.backend
        ..holdPlay = true
        ..holdSeek = true;
      final opening = fixture.player.open();
      await fixture.backend.playEntered.future;
      expect(fixture.player.ready, true);
      final moving = fixture.player.seek(
        Duration.zero,
        source: SeekSource.slider,
      );
      await fixture.backend.seekEntered.future;
      fixture.backend.playRelease.complete();
      await opening;
      await Future<void>.delayed(Duration.zero);
      expect(
        fixture.reports
            .where((path) => path.endsWith('/Sessions/Playing'))
            .length,
        1,
      );
      expect(
        fixture.store.localProgress(fixture.player.account, 'movie'),
        isNull,
      );
      fixture.backend.seekRelease.complete();
      await moving;
      await fixture.player.report('Progress');
      expect(
        fixture.store.localProgress(fixture.player.account, 'movie'),
        Duration.zero,
      );
    },
  );
}
