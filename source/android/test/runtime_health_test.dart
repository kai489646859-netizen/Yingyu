import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'package:yingyu/playback/position_guard.dart';

RuntimeSample sample(
  int now,
  int position,
  int? audio, {
  bool playing = true,
  bool buffering = false,
  bool seeking = false,
  bool cachePaused = false,
  bool ready = true,
  String hardware = 'mediacodec-copy',
}) => RuntimeSample(
  now: Duration(seconds: now),
  position: Duration(seconds: position),
  audioPosition: audio == null ? null : Duration(seconds: audio),
  playing: playing,
  buffering: buffering,
  seeking: seeking,
  cachePaused: cachePaused,
  outputReady: ready,
  hardware: hardware,
);

void main() {
  test('regression with continuing audio triggers one bounded recovery', () {
    final watch = RuntimeHealthWatch();
    expect(watch.sample(sample(0, 2389, 2389), speed: 3), RuntimeAction.none);
    expect(watch.sample(sample(2, 0, 2395), speed: 3), RuntimeAction.none);
    expect(watch.sample(sample(6, 0, 2407), speed: 3), RuntimeAction.recover);
    watch.beginRecovery(
      const Duration(seconds: 2389),
      const Duration(seconds: 6),
    );
    expect(
      watch.sample(sample(8, 2389, 2389, hardware: 'no'), speed: 3),
      RuntimeAction.none,
    );
    expect(
      watch.sample(sample(10, 2395, 2395, hardware: 'no'), speed: 3),
      RuntimeAction.recovered,
    );
    expect(
      watch.sample(sample(16, 2395, 2413, hardware: 'no'), speed: 3),
      RuntimeAction.fail,
    );
  });
  for (final mode in [
    'paused',
    'buffering',
    'seeking',
    'cache',
    'no-output',
    'no-audio',
  ]) {
    test('$mode does not trigger decoder recovery', () {
      final watch = RuntimeHealthWatch();
      for (var i = 0; i <= 40; i += 2) {
        expect(
          watch.sample(
            sample(
              i,
              10,
              mode == 'no-audio' ? null : i * 3,
              playing: mode != 'paused',
              buffering: mode == 'buffering',
              seeking: mode == 'seeking',
              cachePaused: mode == 'cache',
              ready: mode != 'no-output',
            ),
            speed: 3,
          ),
          RuntimeAction.none,
        );
      }
    });
  }
  test(
    'advancing picture clock, even with a static scene or drops, is healthy',
    () {
      final watch = RuntimeHealthWatch();
      for (var i = 0; i < 100; i += 2) {
        expect(
          watch.sample(sample(i, i * 3, i * 3), speed: 3),
          RuntimeAction.none,
        );
      }
    },
  );
  test('texture alone cannot pass recovery and playing time is bounded', () {
    final watch = RuntimeHealthWatch();
    watch.beginRecovery(const Duration(seconds: 200), Duration.zero);
    expect(
      watch.sample(sample(1, 200, 201, hardware: 'no'), speed: 3),
      RuntimeAction.none,
    );
    expect(
      watch.sample(sample(31, 200, 290, hardware: 'no'), speed: 3),
      RuntimeAction.fail,
    );
  });
  test('missing audio at target does not poison later recovery evidence', () {
    final watch = RuntimeHealthWatch()
      ..beginRecovery(
        const Duration(seconds: 6),
        Duration.zero,
        hardware: 'mediacodec-copy',
      );
    expect(watch.sample(sample(2, 6, null), speed: 1), RuntimeAction.none);
    expect(watch.sample(sample(4, 8, 8), speed: 1), RuntimeAction.none);
    expect(watch.sample(sample(6, 10, 10), speed: 1), RuntimeAction.recovered);
  });
  for (final mode in ['no-output', 'wrong-hardware', 'seeking', 'paused']) {
    test('$mode cannot anchor or bridge recovery confirmation', () {
      final watch = RuntimeHealthWatch()
        ..beginRecovery(
          const Duration(seconds: 6),
          Duration.zero,
          hardware: 'mediacodec-copy',
        );
      expect(watch.sample(sample(1, 6, 6), speed: 1), RuntimeAction.none);
      expect(
        watch.sample(
          sample(
            2,
            7,
            7,
            ready: mode != 'no-output',
            hardware: mode == 'wrong-hardware' ? 'no' : 'mediacodec-copy',
            seeking: mode == 'seeking',
            playing: mode != 'paused',
          ),
          speed: 1,
        ),
        RuntimeAction.none,
      );
      expect(watch.sample(sample(4, 8, 8), speed: 1), RuntimeAction.none);
      expect(
        watch.sample(sample(6, 10, 10), speed: 1),
        RuntimeAction.recovered,
      );
    });
  }
  test('recovery clocks can reset before a fresh advancing pair', () {
    final watch = RuntimeHealthWatch()
      ..beginRecovery(
        const Duration(seconds: 6),
        Duration.zero,
        hardware: 'mediacodec-copy',
      );
    expect(watch.sample(sample(2, 8, 30), speed: 1), RuntimeAction.none);
    expect(watch.sample(sample(4, 6, 6), speed: 1), RuntimeAction.none);
    expect(watch.sample(sample(6, 8, 8), speed: 1), RuntimeAction.recovered);
  });
  test('zero video and missing audio keep the one recovery deadline', () {
    final watch = RuntimeHealthWatch()
      ..beginRecovery(
        const Duration(milliseconds: 5964),
        const Duration(milliseconds: 40392),
        hardware: 'mediacodec-copy',
      );
    for (final row in <List<int?>>[
      [42388, 7621],
      [44388, 9621],
      [46388, 11621],
      [50388, 15621],
      [52388, 17621],
      [54388, null],
      [56388, null],
      [58388, null],
    ]) {
      expect(
        watch.sample(
          RuntimeSample(
            now: Duration(milliseconds: row[0]!),
            position: Duration.zero,
            audioPosition: row[1] == null
                ? null
                : Duration(milliseconds: row[1]!),
            playing: true,
            buffering: false,
            seeking: false,
            cachePaused: false,
            outputReady: true,
            hardware: 'mediacodec-copy',
          ),
          speed: 1,
        ),
        RuntimeAction.none,
      );
    }
    expect(watch.recovering, isTrue);
    expect(watch.attempted, isTrue);
    expect(watch.sample(sample(73, 0, null), speed: 1), RuntimeAction.fail);
    expect(watch.attempted, isTrue);
    watch.sample(sample(74, 0, 20), speed: 1);
    expect(watch.sample(sample(80, 0, 26), speed: 1), RuntimeAction.fail);
  });
  test(
    'pause and background do not count as recovery playback or auto resume',
    () {
      final watch = RuntimeHealthWatch();
      watch.beginRecovery(const Duration(seconds: 200), Duration.zero);
      for (var i = 0; i < 120; i += 2) {
        expect(
          watch.sample(sample(i, 200, 200, playing: false), speed: 3),
          RuntimeAction.none,
        );
      }
      expect(
        watch.sample(sample(120, 200, 200, hardware: 'no'), speed: 3),
        RuntimeAction.none,
      );
      expect(
        watch.sample(sample(122, 206, 206, hardware: 'no'), speed: 3),
        RuntimeAction.recovered,
      );
    },
  );
  test(
    'user seek cancels stale verification without resetting attempt budget',
    () {
      final watch = RuntimeHealthWatch();
      watch.beginRecovery(const Duration(seconds: 200), Duration.zero);
      watch.seek();
      expect(watch.recovering, isFalse);
      watch.sample(sample(60, 20, 20), speed: 3);
      expect(watch.sample(sample(66, 20, 38), speed: 3), RuntimeAction.fail);
    },
  );
  test(
    'position guard permits explicit zero and ignores stale seek snapshots',
    () {
      final guard = PlaybackPositionGuard()
        ..reset(const Duration(seconds: 2389));
      expect(guard.accept(Duration.zero), isFalse);
      expect(guard.value.inSeconds, 2389);
      guard.beginSeek(const Duration(seconds: 120));
      expect(guard.accept(const Duration(seconds: 2389)), isFalse);
      expect(guard.value.inSeconds, 120);
      expect(guard.accept(const Duration(seconds: 121)), isTrue);
      guard.beginSeek(Duration.zero);
      expect(guard.accept(Duration.zero), isTrue);
    },
  );
  test('unknown and nonfinite clocks are not converted into a valid zero', () {
    for (final value in [
      'unavailable',
      'nan',
      'inf',
      '-1',
      '1000000000000',
      '',
    ]) {
      expect(mediaClock(value), isNull);
    }
    expect(mediaClock('2389.178')?.inMilliseconds, 2389178);
  });
}
