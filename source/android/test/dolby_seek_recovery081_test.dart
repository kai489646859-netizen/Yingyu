import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/dolby_recovery.dart';
import 'package:yingyu/playback/dolby_source.dart';
import 'package:yingyu/playback/runtime_health.dart';

Duration ms(int value) => Duration(milliseconds: value);

RuntimeSample output(
  int now,
  int position, {
  int? audio,
  bool hasAudio = true,
  bool playing = true,
  bool buffering = false,
  bool seeking = false,
  bool cachePaused = false,
  bool outputReady = true,
  String hardware = 'mediacodec',
}) => RuntimeSample(
  now: ms(now),
  position: ms(position),
  audioPosition: hasAudio ? ms(audio ?? position - 20) : null,
  playing: playing,
  buffering: buffering,
  seeking: seeking,
  cachePaused: cachePaused,
  outputReady: outputReady,
  hardware: hardware,
);

void main() {
  test('the generic mapper error is distinct from confirmed Dolby pairing', () {
    const message = 'Mapping hardware decoded surface failed.';
    expect(
      classifyDolbyOutputFailure('vo/gpu-next', 'error', message),
      DolbyOutputFailure.mapping,
    );
    expect(isDolbyOutputFailure('vo/gpu-next', 'error', message), isFalse);
    for (final message in [
      'Dolby surface timestamp does not match codec output',
      'Timed out matching a Dolby surface to its metadata',
    ]) {
      expect(
        classifyDolbyOutputFailure(
          'vo/gpu-next/aimagereader',
          'error',
          message,
        ),
        DolbyOutputFailure.pairing,
      );
      expect(
        isDolbyOutputFailure('vo/gpu-next/aimagereader', 'error', message),
        isTrue,
      );
    }
    expect(
      classifyDolbyOutputFailure(
        'vo/gpu-next/libplacebo',
        'error',
        'Raw external YUV sampling is unavailable',
      ),
      DolbyOutputFailure.capability,
    );
  });

  test('known native metadata failures remain fatal with the video prefix', () {
    for (final message in [
      'Dolby metadata input cannot be paired safely',
      'Dolby output metadata pairing failed',
    ]) {
      expect(
        classifyDolbyOutputFailure(
          'ffmpeg/video/hevc_mediacodec',
          'error',
          message,
        ),
        DolbyOutputFailure.pairing,
      );
      for (final prefix in ['ffmpeg/audio', 'ffmpeg/video-other', 'vo/gpu']) {
        expect(
          classifyDolbyOutputFailure(prefix, 'error', message),
          DolbyOutputFailure.none,
        );
      }
    }
  });

  test(
    'unrelated prefixes, warnings and unrecognized text do not gain meaning',
    () {
      const message = 'Mapping hardware decoded surface failed.';
      for (final prefix in ['vo/gpu', 'vo/gpu-next-other', 'ad', 'stream']) {
        expect(
          classifyDolbyOutputFailure(prefix, 'error', message),
          DolbyOutputFailure.none,
        );
      }
      expect(
        classifyDolbyOutputFailure('vo/gpu-next', 'warn', message),
        DolbyOutputFailure.none,
      );
      expect(
        classifyDolbyOutputFailure(
          'vo/gpu-next',
          'error',
          'Failed rendering frame!',
        ),
        DolbyOutputFailure.none,
      );
    },
  );

  late DolbySeekRecovery watch;
  late int token;

  DolbyRecoveryAction fault(
    DolbyOutputFailure issue, {
    int now = 8,
    bool opening = false,
    bool playing = true,
    String hardware = 'mediacodec',
  }) => watch.fault(
    issue,
    now: ms(now),
    opening: opening,
    currentHardware: hardware,
    playing: playing,
  );

  DolbyRecoveryAction sample(RuntimeSample value, {double speed = 1}) =>
      watch.sample(value, generation: token, speed: speed);

  void begin({
    int target = 80000,
    String hardware = 'mediacodec',
    bool playing = true,
  }) {
    token = watch.beginSeek(
      target: ms(target),
      now: Duration.zero,
      hardware: hardware,
      playing: playing,
    );
  }

  void repair({bool restart = true}) {
    expect(
      fault(DolbyOutputFailure.mapping),
      DolbyRecoveryAction.rebuildHardware,
    );
    expect(watch.repairStarted(generation: token, now: ms(10)), isTrue);
    if (restart) watch.restarted();
    watch.repairCompleted(generation: token);
  }

  setUp(() {
    watch = DolbySeekRecovery();
    begin();
  });

  test(
    'one mapping failure needs a new restart and advancing target audio/video',
    () {
      repair();
      expect(watch.trackingSeek, isTrue);
      expect(watch.target, ms(80000));
      expect(watch.hardware, 'mediacodec');
      expect(watch.recovering, isTrue);
      expect(sample(output(1000, 80500)), DolbyRecoveryAction.none);
      expect(sample(output(2000, 81500)), DolbyRecoveryAction.recovered);
      expect(watch.recovering, isFalse);
      expect(watch.trackingSeek, isFalse);
      expect(watch.attempted, isTrue);
    },
  );

  test('successful commands and ready dimensions cannot replace a restart', () {
    repair(restart: false);
    expect(sample(output(1000, 80500)), DolbyRecoveryAction.none);
    expect(sample(output(2000, 81500)), DolbyRecoveryAction.none);
    expect(watch.recovering, isTrue);
    watch.restarted();
    expect(sample(output(3000, 82000)), DolbyRecoveryAction.none);
    expect(sample(output(4000, 83000)), DolbyRecoveryAction.recovered);
  });

  test('queued mapper duplicates join one rebuild, not another retry', () {
    expect(
      fault(DolbyOutputFailure.mapping),
      DolbyRecoveryAction.rebuildHardware,
    );
    expect(fault(DolbyOutputFailure.mapping, now: 9), DolbyRecoveryAction.none);
    expect(watch.repairStarted(generation: token, now: ms(10)), isTrue);
    expect(watch.repairStarted(generation: token, now: ms(11)), isFalse);
    expect(
      fault(DolbyOutputFailure.mapping, now: 12),
      DolbyRecoveryAction.none,
    );
    watch.repairCompleted(generation: token);
    expect(
      fault(DolbyOutputFailure.mapping, now: 14),
      DolbyRecoveryAction.fail,
    );
    expect(watch.recovering, isFalse);
  });

  test(
    'confirmed pairing and capability failures never receive a grace period',
    () {
      for (final issue in [
        DolbyOutputFailure.pairing,
        DolbyOutputFailure.capability,
      ]) {
        watch.reset();
        begin();
        expect(fault(issue), DolbyRecoveryAction.fail);
        expect(watch.attempted, isFalse);
        watch.reset();
        begin();
        repair();
        expect(fault(issue, now: 20), DolbyRecoveryAction.fail);
      }
    },
  );

  test(
    'mapping during opening, outside a seek or with unknown hardware fails',
    () {
      expect(
        fault(DolbyOutputFailure.mapping, opening: true),
        DolbyRecoveryAction.fail,
      );
      watch.reset();
      expect(fault(DolbyOutputFailure.mapping), DolbyRecoveryAction.fail);
      for (final hardware in ['', 'no', 'auto', 'vaapi']) {
        watch.reset();
        begin(hardware: hardware);
        expect(
          fault(DolbyOutputFailure.mapping, hardware: hardware),
          DolbyRecoveryAction.fail,
        );
      }
      watch.reset();
      begin();
      expect(
        fault(DolbyOutputFailure.mapping, hardware: 'mediacodec-copy'),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test(
    'a subsequent seek cancels obsolete async repair without refilling budget',
    () {
      repair();
      final obsolete = token;
      token = watch.beginSeek(
        target: ms(30000),
        now: ms(1000),
        hardware: 'mediacodec',
        playing: true,
      );
      expect(watch.target, ms(30000));
      expect(watch.repairStarted(generation: obsolete, now: ms(1100)), isFalse);
      watch.repairCompleted(generation: obsolete);
      expect(
        watch.sample(output(2000, 81500), generation: obsolete, speed: 1),
        DolbyRecoveryAction.none,
      );
      expect(watch.target, ms(30000));
      expect(
        fault(DolbyOutputFailure.mapping, now: 2100),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test('only a new media reset permits another single retry', () {
    repair();
    expect(sample(output(1000, 80500)), DolbyRecoveryAction.none);
    expect(sample(output(2000, 81500)), DolbyRecoveryAction.recovered);
    begin();
    expect(fault(DolbyOutputFailure.mapping), DolbyRecoveryAction.fail);
    watch.reset();
    begin();
    expect(
      fault(DolbyOutputFailure.mapping),
      DolbyRecoveryAction.rebuildHardware,
    );
  });

  test('far-ahead old output cannot validate a backwards target', () {
    repair();
    expect(sample(output(1000, 2760000)), DolbyRecoveryAction.none);
    expect(sample(output(2000, 2761000)), DolbyRecoveryAction.none);
    expect(watch.recovering, isTrue);
    expect(sample(output(3000, 81000)), DolbyRecoveryAction.none);
    expect(sample(output(4000, 82000)), DolbyRecoveryAction.recovered);
  });

  test(
    'old audio, missing audio and a frozen video cannot validate output',
    () {
      repair();
      expect(
        sample(output(1000, 80500, audio: 20000)),
        DolbyRecoveryAction.none,
      );
      expect(
        sample(output(2000, 81500, hasAudio: false)),
        DolbyRecoveryAction.none,
      );
      expect(sample(output(3000, 82000)), DolbyRecoveryAction.none);
      expect(
        sample(output(4000, 82000, audio: 82000)),
        DolbyRecoveryAction.none,
      );
      expect(watch.recovering, isTrue);
      expect(sample(output(5000, 83000)), DolbyRecoveryAction.recovered);
    },
  );

  test(
    'buffering, seeking, missing output and changed decoder reset verification',
    () {
      for (final unavailable in [
        output(2000, 81500, buffering: true),
        output(2000, 81500, seeking: true),
        output(2000, 81500, cachePaused: true),
        output(2000, 81500, outputReady: false),
        output(2000, 81500, hardware: 'no'),
      ]) {
        watch.reset();
        begin();
        repair();
        expect(sample(output(1000, 80500)), DolbyRecoveryAction.none);
        expect(sample(unavailable), DolbyRecoveryAction.none);
        expect(sample(output(3000, 82000)), DolbyRecoveryAction.none);
        expect(sample(output(4000, 83000)), DolbyRecoveryAction.recovered);
      }
    },
  );

  test('audio regression resets the advancing-output anchor', () {
    repair();
    expect(sample(output(1000, 80500, audio: 80480)), DolbyRecoveryAction.none);
    expect(sample(output(1100, 80600, audio: 80580)), DolbyRecoveryAction.none);
    expect(sample(output(1200, 81000, audio: 80400)), DolbyRecoveryAction.none);
    expect(
      sample(output(2000, 81500, audio: 81480)),
      DolbyRecoveryAction.recovered,
    );
  });

  test(
    'paused intervals neither verify output nor consume playback timeout',
    () {
      repair();
      expect(sample(output(1000, 80500)), DolbyRecoveryAction.none);
      expect(
        sample(output(60000, 80500, playing: false)),
        DolbyRecoveryAction.none,
      );
      expect(
        sample(output(120000, 80500, playing: false)),
        DolbyRecoveryAction.none,
      );
      expect(watch.recovering, isTrue);
      expect(sample(output(130000, 80500)), DolbyRecoveryAction.none);
      expect(sample(output(131000, 81500)), DolbyRecoveryAction.recovered);
    },
  );

  test(
    'thirty seconds of requested playback fails with unavailable output',
    () {
      repair();
      expect(
        sample(output(1000, 80000, buffering: true)),
        DolbyRecoveryAction.none,
      );
      expect(
        sample(output(30000, 80000, buffering: true)),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test('player pause events split a slow probe and queued-repair budget', () {
    expect(
      fault(DolbyOutputFailure.mapping),
      DolbyRecoveryAction.rebuildHardware,
    );
    watch.playbackChanged(now: ms(1000), playing: false);
    expect(watch.repairStarted(generation: token, now: ms(60000)), isTrue);
    watch.repairCompleted(generation: token);
    watch.restarted();
    expect(
      sample(output(60000, 80000, playing: false)),
      DolbyRecoveryAction.none,
    );
    watch.playbackChanged(now: ms(61000), playing: true);
    expect(sample(output(62000, 80500)), DolbyRecoveryAction.none);
    expect(sample(output(63000, 81500)), DolbyRecoveryAction.recovered);
  });

  test('repeated between-probe pauses cannot replenish the playing budget', () {
    repair();
    for (var i = 0; i < 29; i++) {
      watch.playbackChanged(now: ms(i * 2000 + 1000), playing: false);
      watch.playbackChanged(now: ms(i * 2000 + 2000), playing: true);
    }
    expect(
      sample(output(58000, 80000, buffering: true)),
      DolbyRecoveryAction.none,
    );
    watch.playbackChanged(now: ms(59000), playing: false);
    expect(
      sample(output(59000, 80000, playing: false)),
      DolbyRecoveryAction.fail,
    );
  });

  test(
    'an obsolete player-state event cannot replace a newer sample state',
    () {
      repair();
      expect(
        sample(output(1000, 80000, buffering: true)),
        DolbyRecoveryAction.none,
      );
      watch.playbackChanged(now: ms(500), playing: false);
      expect(
        sample(output(30000, 80000, buffering: true)),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test(
    'a late fault cannot extend the original thirty-second seek deadline',
    () {
      expect(
        fault(DolbyOutputFailure.mapping, now: 25000),
        DolbyRecoveryAction.rebuildHardware,
      );
      expect(watch.repairStarted(generation: token, now: ms(25010)), isTrue);
      watch.repairCompleted(generation: token);
      watch.restarted();
      expect(
        sample(output(29000, 80000, buffering: true)),
        DolbyRecoveryAction.none,
      );
      expect(
        sample(output(30000, 80000, buffering: true)),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test(
    'a long rate queue cannot start rebuilding after the original deadline',
    () {
      expect(
        fault(DolbyOutputFailure.mapping),
        DolbyRecoveryAction.rebuildHardware,
      );
      expect(watch.repairStarted(generation: token, now: ms(30000)), isFalse);
      expect(watch.repairing, isFalse);
      expect(
        sample(output(30000, 80000, buffering: true)),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test(
    'ordinary successful seek closes the recovery window without spending a retry',
    () {
      expect(watch.trackingSeek, isTrue);
      watch.restarted();
      expect(sample(output(1000, 80500)), DolbyRecoveryAction.none);
      expect(sample(output(2000, 81500)), DolbyRecoveryAction.none);
      expect(watch.attempted, isFalse);
      expect(watch.trackingSeek, isFalse);
      expect(
        fault(DolbyOutputFailure.mapping, now: 2100),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test('speed changes are observed without modifying the hardware choice', () {
    repair();
    expect(sample(output(1000, 82000), speed: 3), DolbyRecoveryAction.none);
    expect(
      sample(output(2000, 85000), speed: 3),
      DolbyRecoveryAction.recovered,
    );
    expect(watch.hardware, 'mediacodec');
  });

  for (final slower in [1.0, 0.5]) {
    test(
      'reducing confirmed speed from three to $slower keeps valid output',
      () {
        repair();
        watch.observeSpeed(3);
        expect(sample(output(1000, 82500), speed: 3), DolbyRecoveryAction.none);
        watch.observeSpeed(slower);
        expect(
          sample(output(2000, 83500), speed: slower),
          DolbyRecoveryAction.recovered,
        );
      },
    );
  }

  test('a confirmed higher speed still rejects old far-ahead output', () {
    repair();
    watch.observeSpeed(3);
    expect(sample(output(1000, 2760000), speed: 3), DolbyRecoveryAction.none);
    watch.observeSpeed(0.5);
    expect(sample(output(2000, 2761000), speed: 0.5), DolbyRecoveryAction.none);
    expect(watch.recovering, isTrue);
  });
}
