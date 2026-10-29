import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;

class _Backend extends FakeBackend {
  final seeks = <Duration>[];
  final gates = <Completer<void>>[];
  final rates = <double>[];
  bool block = false;
  Completer<void>? rateGate;
  @override
  Future<void> seek(Duration at) async {
    seeks.add(at);
    if (block) {
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
    }
    await super.seek(at);
  }

  @override
  Future<void> rate(double value) async {
    rates.add(value);
    await rateGate?.future;
    await super.rate(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late _Backend backend;
  late PlaybackSession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    api = EmbyClient(
      client: MockClient(
        (r) async => r.url.path.endsWith('PlaybackInfo')
            ? response(jsonEncode(playbackData()), 200)
            : r.url.path.contains('Sessions/Playing')
            ? response('', 204)
            : response('{"Id":"movie","Type":"Movie"}', 200),
      ),
    )..session = syntheticSession();
    backend = _Backend()..gate.complete();
    session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    await session.open();
  });
  tearDown(() async {
    await session.close();
    api.close();
    await store.log.flush();
    store.log.dispose();
    store.dispose();
  });
  for (final base in [2.0, 3.0]) {
    test('slider seek retains selected $base speed', () async {
      await session.setSpeed(base, source: SpeedChangeSource.menu);
      await session.seek(
        const Duration(minutes: 15),
        source: SeekSource.slider,
      );
      expect(session.speed, base);
      expect(backend.speed, base);
      expect(backend.rates, [base]);
      expect(backend.seeks, [const Duration(minutes: 15)]);
    });
    for (final held in [2.0, 3.0]) {
      test(
        '$base base with $held hold restores before seek and ignores late release',
        () async {
          await session.setSpeed(base, source: SpeedChangeSource.menu);
          await session.beginSpeedHold(held);
          await session.seek(
            const Duration(minutes: 30),
            source: SeekSource.slider,
          );
          expect(session.holdingSpeed, false);
          expect(backend.speed, base);
          await session.endSpeedHold(source: SpeedChangeSource.holdEnd);
          expect(backend.speed, base);
          expect(session.speed, base);
        },
      );
    }
  }
  for (final fails in [false, true]) {
    test(
      'superseded seek ${fails ? 'failure' : 'completion'} cannot reset latest position or unlock speed',
      () async {
        await session.setSpeed(3);
        backend.block = true;
        final first = session.seek(const Duration(seconds: 100));
        await Future<void>.delayed(Duration.zero);
        final second = session.seek(const Duration(seconds: 800));
        await Future<void>.delayed(Duration.zero);
        expect(backend.gates.length, 2);
        if (fails) {
          backend.gates[0].completeError(const AppFailure('old seek failed'));
        } else {
          backend.gates[0].complete();
        }
        await first;
        expect(session.seeking, true);
        expect(session.position, const Duration(seconds: 800));
        expect(session.canChangeSpeed, false);
        backend.gates[1].complete();
        await second;
        expect(session.seeking, false);
        expect(session.speed, 3);
        expect(session.position, const Duration(seconds: 800));
      },
    );
  }
  test(
    'multiple seeks waiting for hold restoration only submit the newest target',
    () async {
      await session.setSpeed(2);
      await session.beginSpeedHold(3);
      final gate = backend.rateGate = Completer<void>();
      final first = session.seek(const Duration(seconds: 100));
      await Future<void>.delayed(Duration.zero);
      final second = session.seek(const Duration(seconds: 900));
      await Future<void>.delayed(Duration.zero);
      expect(backend.seeks, isEmpty);
      gate.complete();
      await Future.wait([first, second]);
      expect(backend.seeks, [const Duration(seconds: 900)]);
      expect(backend.speed, 2);
    },
  );
}
