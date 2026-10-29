import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_buffer_phase.dart';
import 'package:yingyu/playback/disc_buffering.dart';

void main() {
  const mib = 1024 * 1024;
  for (final speed in [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
    test('opening and every seek keep a low gate at selected $speed', () {
      final phase = DiscBufferPhase()..begin();
      for (var seek = 0; seek < 3; seek++) {
        final first = DiscBufferPlan(
          speed: speed,
          fast: phase.fast,
          baseBytes: 128 * mib,
          memoryMiB: 128,
        );
        expect(first.options['cache-pause-wait'], '2.00');
        expect(first.bytes, 128 * mib);
        phase.arm();
        phase.restart();
        expect(
          phase.canPromote(
            sampleEpoch: phase.epoch,
            outputReady: true,
            buffering: false,
            cachePaused: false,
            seeking: false,
          ),
          isTrue,
        );
        phase.complete(phase.epoch);
        final steady = DiscBufferPlan(
          speed: speed,
          fast: phase.fast,
          baseBytes: 128 * mib,
          memoryMiB: 128,
        );
        expect(
          steady.tier,
          speed <= 1
              ? 1
              : speed <= 2
              ? 2
              : 3,
        );
        expect(
          steady.options['cache-pause-wait'],
          speed <= 1
              ? '2.00'
              : speed <= 2
              ? '4.00'
              : '24.00',
        );
        phase.begin();
      }
    });
  }
  test('sizes, stale restart and completed command alone cannot promote', () {
    final phase = DiscBufferPhase()..begin();
    bool ready({
      bool frame = true,
      bool buffer = false,
      bool cache = false,
      bool seek = false,
      int? epoch,
    }) => phase.canPromote(
      sampleEpoch: epoch ?? phase.epoch,
      outputReady: frame,
      buffering: buffer,
      cachePaused: cache,
      seeking: seek,
    );
    phase.restart(); // Before the media command was armed.
    phase.arm();
    expect(ready(), isFalse);
    phase.restart();
    expect(ready(frame: false), isFalse);
    expect(ready(buffer: true), isFalse);
    expect(ready(cache: true), isFalse);
    expect(ready(seek: true), isFalse);
    final oldEpoch = phase.epoch;
    phase.begin();
    phase.arm();
    phase.restart();
    expect(ready(epoch: oldEpoch), isFalse);
    expect(ready(), isTrue);
    phase.cancel();
    expect(ready(), isFalse);
  });
  test(
    '1.25 and 1.5 share 2x capacity; reducing rate does not retain 3x budget',
    () {
      DiscBufferPlan plan(double speed, int memory) => DiscBufferPlan(
        speed: speed,
        fast: false,
        baseBytes: 128 * mib,
        memoryMiB: memory,
      );
      expect(plan(1.25, 128).options, plan(2, 128).options);
      expect(plan(1.5, 128).options, plan(2, 128).options);
      expect(plan(3, 128).bytes, 768 * mib);
      expect(plan(1.25, 128).bytes, 384 * mib);
      expect(plan(1, 128).bytes, 128 * mib);
      expect(plan(3, 32).bytes, 128 * mib);
      expect(plan(3, 64).bytes, 384 * mib);
    },
  );
  test(
    'a queued promotion cannot overwrite a newer seek or held-rate release',
    () async {
      final phase = DiscBufferPhase()
        ..begin()
        ..arm()
        ..restart();
      final applying = Completer<void>(), entered = Completer<void>();
      final writes = <String>[];
      var speed = 1.25;
      final queue = PlaybackRateQueue((value) async {
        if (value == 3) {
          entered.complete();
          await applying.future;
        }
        speed = value;
        writes.add('rate:$value');
      });
      final hold = queue.set(3);
      await entered.future;
      final oldEpoch = phase.epoch;
      final promotion = queue.run(() async {
        if (oldEpoch == phase.epoch) writes.add('stale promotion');
      });
      phase.cancel(); // A new seek invalidates probes immediately.
      final seek = queue.run(() async {
        phase.begin();
        writes.add('quick seek');
      });
      final release = queue.set(1.25);
      applying.complete();
      await Future.wait([hold, promotion, seek, release]);
      expect(writes, ['rate:3.0', 'quick seek', 'rate:1.25']);
      expect(speed, 1.25);
      expect(phase.fast, isTrue);
    },
  );
  test(
    'a failed optional promotion or command does not block the next rate',
    () async {
      final applied = <double>[];
      final queue = PlaybackRateQueue((value) async => applied.add(value));
      await expectLater(
        queue.run(() async => throw StateError('synthetic failure')),
        throwsStateError,
      );
      await queue.set(2);
      expect(applied, [2]);
    },
  );
}
