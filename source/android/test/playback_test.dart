import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, playbackData, response;

class FakeBackend implements PlayerBackend {
  final updates = StreamController<PlaybackSnapshot>.broadcast();
  final failures = StreamController<String>.broadcast();
  final opened = Completer<void>();
  final gate = Completer<void>();
  bool disposed = false;
  int plays = 0;
  double speed = 1;
  Duration? initial;
  PlaybackRoute? receivedRoute;
  @override
  PlaybackSnapshot snapshot = const PlaybackSnapshot(
    duration: Duration(minutes: 90),
  );
  @override
  Stream<PlaybackSnapshot> get changes => updates.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  List<TrackOption> get audioTracks => [];
  @override
  List<TrackOption> get subtitleTracks => [];
  @override
  Widget view(BoxFit fit) => const ColoredBox(color: Colors.black);
  @override
  Future<void> open(PlaybackRoute route, Duration start) async {
    receivedRoute = route;
    initial = start;
    opened.complete();
    await gate.future;
  }

  @override
  Future<void> play() async {
    plays++;
    snapshot = PlaybackSnapshot(
      playing: true,
      position: snapshot.position,
      duration: snapshot.duration,
    );
    updates.add(snapshot);
  }

  @override
  Future<void> pause() async {
    snapshot = PlaybackSnapshot(
      position: snapshot.position,
      duration: snapshot.duration,
    );
    if (!disposed) updates.add(snapshot);
  }

  @override
  Future<void> seek(Duration position) async {
    snapshot = PlaybackSnapshot(
      position: position,
      duration: snapshot.duration,
      playing: snapshot.playing,
    );
    updates.add(snapshot);
  }

  @override
  Future<void> rate(double value) async {
    speed = value;
  }

  @override
  Future<void> audio(TrackOption track) async {}
  @override
  Future<void> subtitle(TrackOption track) async {}
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await updates.close();
    await failures.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeBackend backend;
  late EmbyClient api;
  late AppStore store;
  late List<http.Request> reports;
  late int serverPosition;
  late bool persistReports;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    backend = FakeBackend();
    reports = [];
    serverPosition = 350000000;
    persistReports = true;
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (request.url.path.contains('Sessions/Playing')) {
          reports.add(request);
          if (persistReports && request.url.path.endsWith('/Stopped')) {
            serverPosition = jsonDecode(request.body)['PositionTicks'] as int;
          }
          return response('', 204);
        }
        return response(
          jsonEncode({
            'Id': 'movie',
            'Name': '合成电影',
            'Type': 'Movie',
            'RunTimeTicks': 54000000000,
            'UserData': {
              'PlaybackPositionTicks': serverPosition,
              'Played': false,
              'PlayCount': 1,
              'IsFavorite': false,
            },
          }),
          200,
        );
      }),
    )..session = syntheticSession();
  });
  PlaybackSession controller() => PlaybackSession(
    api: api,
    store: store,
    item: MediaItem({'Id': 'movie'}),
    backend: backend,
  );
  test(
    'waits for actual backend readiness before play and started report',
    () async {
      final player = controller();
      final open = player.open();
      await backend.opened.future;
      expect(player.loading, true);
      expect(reports, isEmpty);
      expect(backend.plays, 0);
      expect(backend.initial, const Duration(seconds: 35));
      backend.gate.complete();
      await open;
      await player.report('Progress');
      expect(player.ready, true);
      expect(backend.plays, 1);
      expect(reports.first.url.path, endsWith('/Sessions/Playing'));
      await player.seek(const Duration(seconds: 42));
      await player.close();
      expect(reports.last.url.path, endsWith('/Stopped'));
      expect(jsonDecode(reports.last.body)['PositionTicks'], 420000000);
      expect(store.localProgress(api.session!, 'movie'), isNull);
      player.dispose();
      api.close();
    },
  );
  test(
    '204 without saved resume keeps the local checkpoint and exposes mismatch',
    () async {
      persistReports = false;
      final player = controller();
      final open = player.open();
      await backend.opened.future;
      backend.gate.complete();
      await open;
      await player.seek(const Duration(minutes: 12));
      await player.report('Progress');
      expect(
        store.localProgress(api.session!, 'movie'),
        const Duration(minutes: 12),
      );
      await player.close();
      expect(player.syncWarning, contains('Emby 尚未返回相同进度'));
      expect(
        store.localProgress(api.session!, 'movie'),
        const Duration(minutes: 12),
      );
      player.dispose();
      api.close();
    },
  );
  test(
    'check-ins report actual duration, speed and buffering pause events',
    () async {
      final player = controller();
      final open = player.open();
      await backend.opened.future;
      backend.gate.complete();
      await open;
      await player.setSpeed(2);
      await player.report('Progress');
      var events = reports
          .map((r) => jsonDecode(r.body) as Map<String, dynamic>)
          .toList();
      expect(events.every((e) => e['RunTimeTicks'] == 54000000000), true);
      expect(
        events.any(
          (e) =>
              e['EventName'] == 'PlaybackRateChange' && e['PlaybackRate'] == 2,
        ),
        true,
      );
      backend.snapshot = const PlaybackSnapshot(
        playing: true,
        buffering: true,
        duration: Duration(minutes: 90),
      );
      backend.updates.add(backend.snapshot);
      await Future<void>.delayed(Duration.zero);
      await player.report('Progress');
      events = reports
          .map((r) => jsonDecode(r.body) as Map<String, dynamic>)
          .toList();
      expect(
        events.any((e) => e['EventName'] == 'Pause' && e['IsPaused'] == true),
        true,
      );
      await player.close();
      player.dispose();
      api.close();
    },
  );
  test(
    'unknown runtime is omitted instead of resetting server duration to zero',
    () async {
      final media = MediaItem({'Id': 'movie'});
      final route = PlaybackRoute(
        url: 'https://unused.invalid/movie',
        sourceId: 'source',
        sessionId: 'play',
        headers: {},
        streams: [],
      );
      await api.report(
        'Progress',
        media,
        route,
        const Duration(minutes: 5),
        false,
        duration: Duration.zero,
      );
      final event = jsonDecode(reports.single.body) as Map<String, dynamic>;
      expect(event.containsKey('RunTimeTicks'), false);
      expect(event['PositionTicks'], 3000000000);
      expect(event['PlaySessionId'], 'play');
      api.close();
    },
  );
  test(
    'real open error never becomes ready or reports successful start',
    () async {
      final player = controller();
      final open = player.open();
      await backend.opened.future;
      backend.gate.completeError(const AppFailure('HTTP 403 无法打开媒体'));
      await open;
      expect(player.ready, false);
      expect(player.error, contains('403'));
      expect(reports, isEmpty);
      expect(backend.plays, 0);
      await player.close();
      player.dispose();
      api.close();
    },
  );
  test(
    'a disc read failure after readiness pauses and exposes retry instead of staying busy',
    () async {
      final player = controller();
      final open = player.open();
      await backend.opened.future;
      backend.gate.complete();
      await open;
      expect(player.ready, true);
      backend.failures.add('原盘读取失败：HTTP 503');
      await Future<void>.delayed(Duration.zero);
      expect(player.error, contains('HTTP 503'));
      expect(player.ready, false);
      expect(player.loading, false);
      expect(backend.snapshot.playing, false);
      player.foreground();
      expect(backend.plays, 1);
      await player.close();
      player.dispose();
      api.close();
    },
  );
  test('closing during open invalidates late completion', () async {
    final player = controller();
    final open = player.open();
    await backend.opened.future;
    await player.close();
    backend.gate.complete();
    await open;
    expect(backend.plays, 0);
    expect(reports, isEmpty);
    expect(backend.disposed, true);
    player.dispose();
    api.close();
  });
  test(
    'background before backend ready pauses; returning does not auto-play',
    () async {
      final player = controller();
      final open = player.open();
      await backend.opened.future;
      await player.pauseForBackground();
      backend.gate.complete();
      await open;
      expect(backend.plays, 0);
      player.foreground();
      expect(backend.plays, 0);
      await player.toggle();
      expect(backend.plays, 1);
      await player.pauseForBackground();
      player.foreground();
      expect(backend.snapshot.playing, false);
      await player.close();
      player.dispose();
      api.close();
    },
  );
  test(
    'resume can explicitly start at zero; seek clamps to known duration',
    () async {
      final player = controller();
      final open = player.open(fromBeginning: true);
      await backend.opened.future;
      expect(backend.initial, Duration.zero);
      backend.gate.complete();
      await open;
      await player.seek(const Duration(seconds: -20));
      expect(player.position, Duration.zero);
      await player.seek(const Duration(hours: 2));
      expect(player.position, const Duration(minutes: 90));
      await player.setSpeed(1.5);
      await player.setSpeed(3);
      await player.setSpeed(1.5);
      expect(backend.speed, 1.5);
      await player.close();
      player.dispose();
      api.close();
    },
  );
  test(
    'progress failures remain visible and retain pending local position',
    () async {
      api.close();
      api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            return response('', 500);
          }
          return response('{"Id":"movie"}', 200);
        }),
      )..session = syntheticSession();
      final player = controller();
      final open = player.open();
      await backend.opened.future;
      backend.gate.complete();
      await open;
      await player.seek(const Duration(seconds: 28));
      await player.close();
      expect(player.syncWarning, contains('500'));
      expect(
        store.localProgress(api.session!, 'movie'),
        const Duration(seconds: 28),
      );
      player.dispose();
      api.close();
    },
  );
}
