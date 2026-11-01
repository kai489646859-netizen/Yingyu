import 'package:flutter_test/flutter_test.dart';
import 'host/power201/old/backend.dart' as old;
import 'host/power201/new/backend.dart' as current;
import 'host/power201/old/worker.dart' as old_worker;
import 'host/power201/new/worker.dart' as worker;

void main() {
  for (final playing in [true, false]) {
    test(
      'logging off preserves every health read while removing diagnostic reads, playing=$playing',
      () async {
        final before = old.BackendHarness(), after = current.BackendHarness();
        final counts = <Map<String, int>>[];
        for (final dynamic b in [before, after]) {
          b.start(disc: false, speed: 1.0);
          b.logEnabled(false);
          final reads = <String, int>{};
          counts.add(reads);
          b.native.beforeRead = (String key) async {
            reads.update(key, (n) => n + 1, ifAbsent: () => 1);
          };
          for (var i = 0; i < 30; i++) {
            final p = playing ? 1.0 + 2 * i : 1.0;
            await b.probeAt(i * 2000, p, p, playing: playing);
          }
          expect(b.failure, isNull);
          expect(b.native.writes, isEmpty);
        }
        expect(counts[0].values.fold<int>(0, (a, b) => a + b), 480);
        expect(counts[1].values.fold<int>(0, (a, b) => a + b), 240);
        for (final key in [
          'current-vo',
          'vo-configured',
          'hwdec-current',
          'video-frame-info/interlaced',
          'time-pos',
          'audio-pts',
          'seeking',
          'paused-for-cache',
        ]) {
          expect(counts[1][key], counts[0][key]);
        }
      },
    );
  }
  test(
    'enabled diagnostics preserve counter intervals and sanitized output while avoiding unused reads',
    () async {
      final states = <List<String>>[];
      final counts = <Map<String, int>>[];
      for (final dynamic b in [
        old.BackendHarness(),
        current.BackendHarness(),
      ]) {
        b.start(disc: false, speed: 1.0);
        final reads = <String, int>{};
        counts.add(reads);
        b.native.beforeRead = (String key) async {
          reads.update(key, (n) => n + 1, ifAbsent: () => 1);
        };
        b.native.values['video-out-params/pixelformat'] = 'p010';
        for (var i = 0; i < 30; i++) {
          b.native.values['frame-drop-count'] = '$i';
          b.native.values['decoder-frame-drop-count'] = '${i * 2}';
          await b.probeAt(i * 2000, 1.0 + i * 2, 1.0 + i * 2);
        }
        states.add(List<String>.from(b.logs));
        expect(b.failure, isNull);
      }
      expect(states[1], states[0]);
      expect(counts[1]['estimated-frame-number'], isNull);
      expect(counts[1]['video-dec-params/pixelformat'], isNull);
      expect(counts[1]['video-out-params/pixelformat'], 6);
      expect(counts[1]['frame-drop-count'], 30);
    },
  );
  for (final speed in [1.0, 2.0, 3.0]) {
    test(
      'missing output fails on the identical sample with diagnostics off at $speed',
      () async {
        final failures = <List<String?>>[];
        for (final dynamic b in [
          old.BackendHarness(),
          current.BackendHarness(),
        ]) {
          b.start(disc: false, speed: speed);
          b.logEnabled(false);
          b.expectVideo();
          final timeline = <String?>[];
          for (var i = 0; i < 8; i++) {
            await b.probeAt(i * 2000, 0.0, 1.0 + i * 2 * speed, ready: false);
            timeline.add(b.failure as String?);
          }
          failures.add(timeline);
        }
        expect(failures[1], failures[0]);
        expect(failures[1].last, isNotNull);
      },
    );
  }
  test(
    'late reads after disposal never query diagnostic fields or write state',
    () async {
      final b = current.BackendHarness()..start(disc: false, speed: 2);
      final keys = <String>[];
      b.native.beforeRead = (key) async {
        keys.add(key);
        b.disposeNow();
      };
      await b.probeAt(0, 1, 1);
      expect(keys, ['current-vo']);
      expect(b.native.writes, isEmpty);
      expect(b.logs, isEmpty);
    },
  );
  test(
    '2x to 3x and back retains old controls and continuous health with logging off',
    () async {
      final states = <Object>[];
      for (final dynamic b in [
        old.BackendHarness(),
        current.BackendHarness(),
      ]) {
        b.start(disc: false, speed: 2.0);
        b.logEnabled(false);
        await b.probeAt(0, 10.0, 10.0);
        await b.confirmRate(3.0, 1000);
        await b.probeAt(2000, 16.0, 16.0);
        await b.confirmRate(2.0, 3000);
        await b.probeAt(4000, 20.0, 20.0);
        expect(b.failure, isNull);
        expect(b.player.rates, [3.0, 2.0]);
        states.add([
          List<double>.from(b.player.rates),
          List<Object>.from(b.native.writes),
        ]);
      }
      expect(states[1], states[0]);
    },
  );
  test(
    're-enabled logging starts a real observation and does not invent disabled-period counters',
    () async {
      final b = current.BackendHarness()..start(disc: false, speed: 1);
      b.logEnabled(false);
      await b.probeAt(0, 1, 1);
      await b.probeAt(2000, 3, 3);
      b.logEnabled(true);
      b.native.values['frame-drop-count'] = '20';
      await b.probeAt(4000, 5, 5);
      expect(b.logs.single, contains('区间统计=首个样本'));
      expect(b.failure, isNull);
    },
  );
  test(
    'optional format read crossing a rate change cannot publish stale diagnostic data',
    () async {
      final b = current.BackendHarness()..start(disc: false, speed: 1);
      b.native.beforeRead = (key) async {
        if (key == 'video-out-params/pixelformat') await b.confirmRate(2, 500);
      };
      await b.probeAt(0, 1, 1);
      expect(b.logs.any((s) => s.startsWith('画面链路采样：')), isFalse);
      expect(b.failure, isNull);
      expect(b.player.rates, [2]);
    },
  );
  testWidgets(
    'worker idle removes periodic snapshots, explicit status remains fresh',
    (tester) async {
      final before = old_worker.WorkerHarness();
      await before.start();
      final after = worker.WorkerHarness();
      await after.start();
      await tester.pump(const Duration(minutes: 1));
      expect(before.events.where((dynamic e) => e[0] == 'status').length, 60);
      expect(after.events.where((dynamic e) => e[0] == 'status'), isEmpty);
      expect(after.transport.reads, 1);
      after.transport.counter = 99;
      final reply = worker.SendPort();
      after.command(['status', reply]);
      expect(reply.sent.single, contains('counter=99'));
      expect(after.transport.reads, 2);
      before.command(['close']);
      after.command(['close']);
      await tester.pump();
    },
  );
  testWidgets(
    'worker speed, buffering, seek and immediate failure remain independent of snapshots',
    (tester) async {
      final w = worker.WorkerHarness();
      await w.start();
      w.command(['speed', 3.0]);
      w.command(['speed', 2.0]);
      w.command(['buffering', true]);
      w.command(['seek']);
      w.transport.onStage('synthetic-stage');
      w.transport.onFailure('synthetic-failure');
      expect(w.transport.rates, [3.0, 2.0]);
      expect(w.transport.buffering, [true]);
      expect(w.transport.seeks, 1);
      expect(
        w.events.any(
          (dynamic e) => e[0] == 'stage' && e[1] == 'synthetic-stage',
        ),
        isTrue,
      );
      expect(
        w.events.any(
          (dynamic e) => e[0] == 'failed' && e[1] == 'synthetic-failure',
        ),
        isTrue,
      );
      w.command(['close']);
      await tester.pump();
      final n = w.events.length;
      await tester.pump(const Duration(minutes: 1));
      expect(w.transport.closes, 1);
      expect(w.events.length, n);
    },
  );
}
