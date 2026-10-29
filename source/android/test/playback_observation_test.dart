import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/observation.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, playbackData, response;
import 'playback_test.dart' show FakeBackend;

class ObservedBackend extends FakeBackend implements PlaybackDiagnosticState {
  bool failRate = false, failSeek = false;
  final rates = <double>[];
  @override
  String get diagnosticState => '合成最近采样；缓存媒体时间=6 秒；缓存暂停=no';
  @override
  Future<void> rate(double value) async {
    rates.add(value);
    if (failRate) throw const AppFailure('合成切速错误');
    await super.rate(value);
  }

  @override
  Future<void> seek(Duration position) async {
    if (failSeek) throw const AppFailure('合成定位错误');
    await super.seek(position);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'samples keep unknowns, omit raw values and reject old operation results',
    () {
      final sample = PlaybackObservation();
      final epoch = sample.generation;
      expect(sample.describe(Duration.zero), contains('尚未取得'));
      sample.record(
        sampleGeneration: epoch,
        now: const Duration(seconds: 1),
        speed: 3,
        values: {
          'demuxer-cache-duration': '6',
          'time-pos': '42',
          'audio-pts': '41.9',
          'speed': '3',
          'decoder-frame-drop-count': '0',
          'frame-drop-count': '35',
          'stream-path': 'https://secret.invalid/token',
          'seeking': 'no',
        },
      );
      final text = sample.describe(const Duration(seconds: 2));
      expect(text, contains('采样距今=1000 ms'));
      expect(text, contains('≈2.00 秒（估算）'));
      expect(text, contains('内核倍速=3'));
      expect(text, isNot(contains('secret')));
      sample.record(
        sampleGeneration: epoch,
        now: const Duration(seconds: 3),
        speed: 3,
        values: {
          'demuxer-cache-duration': 'NaN',
          'frame-drop-count': '39',
          'decoder-frame-drop-count': '0',
          'time-pos': 'https://secret.invalid/',
        },
      );
      final invalid = sample.describe(const Duration(seconds: 3));
      expect(invalid, contains('输出丢帧新增=4'));
      expect(invalid, contains('采样间隔=2000 ms'));
      expect(invalid, contains('缓存媒体时间=未提供'));
      expect(invalid, isNot(contains('secret')));
      sample.invalidate();
      expect(
        sample.record(
          sampleGeneration: epoch,
          now: const Duration(seconds: 4),
          speed: 3,
          values: {'time-pos': '0'},
        ),
        false,
      );
      expect(sample.describe(const Duration(seconds: 4)), contains('尚未取得'));
    },
  );

  test('counter resets are explicit and never become negative frame drops', () {
    final sample = PlaybackObservation();
    for (final pair in [(1, '64'), (3, '0')]) {
      sample.record(
        sampleGeneration: sample.generation,
        now: Duration(seconds: pair.$1),
        speed: 1,
        values: {'frame-drop-count': pair.$2},
      );
    }
    expect(
      sample.describe(const Duration(seconds: 3)),
      contains('输出丢帧新增=计数已重置'),
    );
  });

  group('session trace stays observational', () {
    late AppStore store;
    late EmbyClient api;
    late ObservedBackend backend;
    late PlaybackSession session;
    var serverMs = 35000;
    late List<String> requests;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      store = AppStore(await SharedPreferences.getInstance());
      serverMs = 35000;
      requests = [];
      api = EmbyClient(
        client: MockClient((request) async {
          requests.add(request.url.path);
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            serverMs =
                (jsonDecode(request.body)['PositionTicks'] as int) ~/ 10000;
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
      backend = ObservedBackend();
      session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      final open = session.open();
      await backend.opened.future;
      backend.gate.complete();
      await open;
      await session.report('Progress');
    });
    tearDown(() async {
      await session.close();
      session.dispose();
      api.close();
      store.log.dispose();
    });
    String logs() => store.log.entries.map((e) => e.message).join('\n');

    test(
      'menu, held speed and restore have sources without extra play or media work',
      () async {
        await session.setSpeed(1.5, source: SpeedChangeSource.menu);
        await session.setSpeed(3, source: SpeedChangeSource.holdStart);
        await session.setSpeed(1.5, source: SpeedChangeSource.holdEnd);
        expect(backend.rates, [1.5, 3, 1.5]);
        expect(backend.speed, 1.5);
        expect(backend.plays, 1);
        final text = logs();
        expect(text, contains('来源=倍速菜单；原倍速=1.0；目标倍速=1.5'));
        expect(text, contains('来源=长按开始'));
        expect(text, contains('来源=长按松手；原倍速=3.0；当前倍速=1.5'));
        expect(requests.where((p) => p.endsWith('PlaybackInfo')), hasLength(1));
        await session.close();
        expect(logs(), contains('倍速命令完成=3；倍速命令失败=0'));
      },
    );

    test(
      'failures stay failures and old rate/progress are not labelled successful',
      () async {
        backend.failRate = true;
        await expectLater(
          session.setSpeed(3, source: SpeedChangeSource.menu),
          throwsA(isA<AppFailure>()),
        );
        expect(session.speed, 1);
        expect(logs(), contains('倍速调整失败'));
        expect(logs(), isNot(contains('当前倍速=3.0')));
        backend.failSeek = true;
        final previous = session.position;
        await expectLater(
          session.seek(const Duration(seconds: 90), source: SeekSource.slider),
          throwsA(isA<AppFailure>()),
        );
        expect(session.position, previous);
        expect(logs(), contains('来源=进度条'));
        expect(logs(), contains('定位命令失败'));
        expect(logs(), isNot(contains('定位命令完成；')));
      },
    );

    test(
      'buffer transitions summarize once and pause sources preserve no auto resume',
      () async {
        for (final buffering in [true, true, false]) {
          backend.snapshot = PlaybackSnapshot(
            position: const Duration(seconds: 35),
            duration: const Duration(minutes: 90),
            playing: true,
            buffering: buffering,
          );
          backend.updates.add(backend.snapshot);
          await Future<void>.delayed(Duration.zero);
        }
        await session.seek(
          const Duration(seconds: 42),
          source: SeekSource.gesture,
        );
        await session.pauseForBackground(source: PauseSource.interruption);
        session.foreground();
        expect(backend.snapshot.playing, false);
        expect(backend.plays, 1);
        await session.close();
        expect(logs(), contains('播放缓冲次数=1'));
        expect(logs(), contains('来源=音频中断'));
        expect(logs(), contains('来源=横滑手势'));
        expect(logs(), contains('画面恢复需核对后续输出与缓冲记录'));
        expect(logs(), contains('合成最近采样'));
        expect(serverMs, 42000);
      },
    );

    test(
      'turning logs off leaves playback actions operational and does not add records',
      () async {
        await store.log.clear();
        await store.log.setEnabled(false);
        await session.setSpeed(3, source: SpeedChangeSource.menu);
        await session.seek(const Duration(seconds: 42));
        await session.close();
        expect(backend.speed, 3);
        expect(serverMs, 42000);
        expect(store.log.entries, isEmpty);
      },
    );
  });
}
