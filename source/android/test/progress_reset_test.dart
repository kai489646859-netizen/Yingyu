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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late FakeBackend backend;
  late PlaybackSession session;
  late List<Map<String, dynamic>> reports;
  late int serverMs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    serverMs = 2300000;
    reports = [];
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (request.url.path.contains('Sessions/Playing')) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          reports.add(body);
          serverMs = (body['PositionTicks'] as int) ~/ 10000;
          return response('', 204);
        }
        return response(
          jsonEncode({
            'Id': 'movie',
            'Type': 'Movie',
            'RunTimeTicks': 54000000000,
            'UserData': {
              'PlaybackPositionTicks': serverMs * 10000,
              'Played': false,
            },
          }),
          200,
        );
      }),
    )..session = syntheticSession();
    backend = FakeBackend();
    session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
  });
  tearDown(() async {
    await session.close();
    session.dispose();
    api.close();
  });
  Future<void> open({bool beginning = false}) async {
    final pending = session.open(fromBeginning: beginning);
    await backend.opened.future;
    backend.gate.complete();
    await pending;
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> sample(
    int milliseconds, {
    bool completed = false,
    bool buffering = false,
  }) async {
    backend.snapshot = PlaybackSnapshot(
      position: Duration(milliseconds: milliseconds),
      duration: const Duration(minutes: 90),
      playing: true,
      completed: completed,
      buffering: buffering,
    );
    backend.updates.add(backend.snapshot);
    await Future<void>.delayed(Duration.zero);
  }

  for (final bad in [0, -1000, 1000, 99999999]) {
    test(
      'unexpected clock $bad cannot erase UI, local checkpoint or server resume',
      () async {
        await open();
        await sample(2389178);
        await session.report('Progress');
        reports.clear();
        await sample(bad);
        await session.setSpeed(3);
        await session.report('Progress');
        expect(session.position.inMilliseconds, 2389178);
        expect(
          store.localProgress(api.session!, 'movie')?.inMilliseconds,
          2389178,
        );
        await session.close();
        expect(serverMs, 2389178);
        expect(reports, isNotEmpty);
        expect(reports.every((r) => r['PositionTicks'] == 23891780000), isTrue);
      },
    );
  }
  test(
    'false completion plus zero mid-film preserves continue watching',
    () async {
      await open();
      await sample(2389178);
      await sample(0, completed: true);
      await session.report('Progress');
      expect(
        store.localProgress(api.session!, 'movie')?.inMilliseconds,
        2389178,
      );
      await session.close();
      expect(serverMs, 2389178);
      expect(session.position.inMilliseconds, 2389178);
    },
  );
  test(
    'explicit backward seek and seek to zero still save intentional progress',
    () async {
      await open();
      await sample(2389178);
      await session.seek(const Duration(minutes: 2));
      await sample(120000);
      await session.report('Progress');
      expect(serverMs, 120000);
      await session.seek(Duration.zero);
      await sample(0);
      await session.close();
      expect(serverMs, 0);
    },
  );
  test(
    'from beginning is allowed even when server has a positive checkpoint',
    () async {
      await open(beginning: true);
      await sample(0);
      await session.close();
      expect(serverMs, 0);
    },
  );
  test(
    'loading transitions record start, recovery and interrupted wait',
    () async {
      await open();
      await sample(2389178, buffering: true);
      await sample(2389178, buffering: true);
      await sample(2390000);
      await sample(2390000, buffering: true);
      await session.close();
      final text = store.log.export();
      expect(text, contains('资源加载开始'));
      expect(text, contains('资源加载结束'));
      expect(text, contains('阶段=播放缓冲'));
      expect(text, contains('结果=恢复播放'));
      expect(text, contains('结果=退出播放'));
    },
  );
}
