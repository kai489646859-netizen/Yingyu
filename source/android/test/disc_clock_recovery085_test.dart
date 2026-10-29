import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_clock_recovery.dart';
import 'package:yingyu/playback/runtime_health.dart';

RuntimeSample point(
  int now,
  double video,
  double? audio, {
  bool buffering = false,
  bool seeking = false,
  bool playing = true,
  bool ready = true,
  String hardware = 'mediacodec-copy',
}) => RuntimeSample(
  now: Duration(seconds: now),
  position: Duration(microseconds: (video * 1e6).round()),
  audioPosition: audio == null
      ? null
      : Duration(microseconds: (audio * 1e6).round()),
  playing: playing,
  buffering: buffering,
  seeking: seeking,
  cachePaused: buffering,
  outputReady: ready,
  hardware: hardware,
);

void main() {
  DiscClockRecoveryEvidence create() =>
      DiscClockRecoveryEvidence()..begin(load: 3, epoch: 4, intent: 5);
  void observe(
    DiscClockRecoveryEvidence guard,
    RuntimeSample sample, {
    int load = 3,
    int epoch = 4,
    int intent = 5,
    bool disc = true,
  }) => guard.observe(
    sample,
    load: load,
    epoch: epoch,
    intent: intent,
    selectedOrdinaryDisc: disc,
  );
  bool qualifies(
    DiscClockRecoveryEvidence guard, {
    int now = 19,
    int load = 3,
    int epoch = 4,
    int intent = 5,
  }) => guard.qualifies(
    load: load,
    epoch: epoch,
    intent: intent,
    now: Duration(seconds: now),
    hardware: 'mediacodec-copy',
  );

  test(
    'actual 084 buffered synchronized frame then running zero regression qualifies load3',
    () {
      final guard = create();
      observe(guard, point(9, 1440.188744, 1440.188729, buffering: true));
      for (final now in [11, 13, 15, 17, 19]) {
        observe(guard, point(now, 0, 1442 + now - 11));
      }
      expect(qualifies(guard), isTrue);
    },
  );
  for (final mode in [
    'no-baseline',
    'ordinary-or-dolby',
    'unknown-audio',
    'no-output',
    'buffering',
    'seeking',
    'paused',
    'jitter',
    'audio-regression',
  ]) {
    test('$mode cannot qualify disc software recovery', () {
      final guard = create();
      if (mode != 'no-baseline') observe(guard, point(9, 1440, 1440));
      for (final now in [11, 13, 15, 17, 19]) {
        observe(
          guard,
          point(
            now,
            mode == 'jitter' ? 1439.95 : 0,
            mode == 'unknown-audio'
                ? null
                : mode == 'audio-regression'
                ? 1430
                : 1440 + now - 9,
            buffering: mode == 'buffering',
            seeking: mode == 'seeking',
            playing: mode != 'paused',
            ready: mode != 'no-output',
          ),
          disc: mode != 'ordinary-or-dolby',
        );
      }
      expect(qualifies(guard), isFalse);
    });
  }
  for (final boundary in [
    'load',
    'epoch',
    'intent',
    'clear',
    'late',
    'sample-gap',
  ]) {
    test('$boundary cannot reuse prior clock evidence', () {
      final guard = create();
      observe(guard, point(9, 1440, 1440));
      for (final now in [11, 13, 15, 17, 19]) {
        observe(guard, point(now, 0, 1440 + now - 9));
      }
      if (boundary == 'clear') guard.clear();
      if (boundary == 'sample-gap') observe(guard, point(27, 0, 1460));
      expect(
        qualifies(
          guard,
          load: boundary == 'load' ? 4 : 3,
          epoch: boundary == 'epoch' ? 6 : 4,
          intent: boundary == 'intent' ? 7 : 5,
          now: boundary == 'late' || boundary == 'sample-gap' ? 27 : 19,
        ),
        isFalse,
      );
    });
  }
  test(
    'strict recovery needs three synchronized samples with observed progress',
    () {
      for (final speed in [.5, 1.0, 2.0, 3.0]) {
        final watch = RuntimeHealthWatch()
          ..beginRecovery(
            const Duration(seconds: 6),
            Duration.zero,
            hardware: 'no',
            requireSynchronizedAv: true,
          );
        expect(
          watch.sample(point(1, 6, 6, hardware: 'no'), speed: speed),
          RuntimeAction.none,
        );
        expect(
          watch.sample(
            point(3, 6 + 2 * speed, 6 + 2 * speed, hardware: 'no'),
            speed: speed,
          ),
          RuntimeAction.none,
        );
        expect(
          watch.sample(
            point(5, 6 + 4 * speed, 6 + 4 * speed, hardware: 'no'),
            speed: speed,
          ),
          RuntimeAction.recovered,
        );
      }
    },
  );
  test(
    'strict recovery accepts a late first sample without aging its clock backwards',
    () {
      final watch = RuntimeHealthWatch()
        ..beginRecovery(
          const Duration(seconds: 6),
          Duration.zero,
          hardware: 'no',
          requireSynchronizedAv: true,
        );
      expect(
        watch.sample(point(4, 10, 10, hardware: 'no'), speed: 1),
        RuntimeAction.none,
      );
      expect(
        watch.sample(point(6, 12, 12, hardware: 'no'), speed: 1),
        RuntimeAction.none,
      );
      expect(
        watch.sample(point(8, 14, 14, hardware: 'no'), speed: 1),
        RuntimeAction.recovered,
      );
    },
  );
  for (final mode in [
    'large-av-drift',
    'both-slow',
    'wrong-hardware',
    'clock-reset',
  ]) {
    test('strict $mode never falsely confirms or extends the deadline', () {
      final watch = RuntimeHealthWatch()
        ..beginRecovery(
          const Duration(seconds: 6),
          Duration.zero,
          hardware: 'no',
          requireSynchronizedAv: true,
        );
      for (var now = 1; now <= 31; now += 2) {
        final elapsed = (now - 1).toDouble();
        final video = mode == 'clock-reset'
            ? 6 + (now % 4 == 1 ? 0 : 1)
            : 6 + elapsed * .1;
        final audio = mode == 'large-av-drift' ? 6 + elapsed : video;
        final action = watch.sample(
          point(
            now,
            video.toDouble(),
            audio.toDouble(),
            hardware: mode == 'wrong-hardware' ? 'mediacodec-copy' : 'no',
          ),
          speed: 1,
        );
        expect(action, now == 31 ? RuntimeAction.fail : RuntimeAction.none);
      }
      expect(watch.attempted, isTrue);
    });
  }
  test(
    'strict confirmed speed history survives decreases before and between probes',
    () {
      for (final initial in [1.0, 3.0]) {
        final watch = RuntimeHealthWatch()
          ..beginRecovery(
            const Duration(seconds: 6),
            Duration.zero,
            hardware: 'no',
            requireSynchronizedAv: true,
            speed: initial,
          );
        if (initial == 1) {
          expect(
            watch.sample(point(1, 7, 7, hardware: 'no'), speed: 1),
            RuntimeAction.none,
          );
          watch.observeSpeed(3);
        }
        watch.observeSpeed(1);
        final position = initial == 3 ? 14.0 : 12.0;
        expect(
          watch.sample(point(4, position, position, hardware: 'no'), speed: 1),
          RuntimeAction.none,
        );
        expect(
          watch.sample(
            point(6, position + 2, position + 2, hardware: 'no'),
            speed: 1,
          ),
          RuntimeAction.none,
        );
        expect(
          watch.sample(
            point(8, position + 4, position + 4, hardware: 'no'),
            speed: 1,
          ),
          RuntimeAction.recovered,
        );
      }
    },
  );
}
