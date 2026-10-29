import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';
import 'package:yingyu/playback/hardware_fallback.dart';
import 'package:yingyu/playback/runtime_health.dart';

const faultText =
    'hevc_mediacodec: Failed to dequeue output buffer (status=-10000)';
RuntimeSample frame(
  int tick,
  int position, {
  String hw = 'no',
  bool playing = true,
  bool seeking = false,
  bool buffering = false,
  bool output = true,
  int? audio,
}) => RuntimeSample(
  now: Duration(seconds: tick),
  position: Duration(milliseconds: position),
  audioPosition: Duration(milliseconds: audio ?? position + 100),
  hardware: hw,
  playing: playing,
  seeking: seeking,
  buffering: buffering,
  cachePaused: buffering,
  outputReady: output,
);
HardwareFallbackWatch broken() => HardwareFallbackWatch()
  ..observeHardware('mediacodec-copy')
  ..fault('ffmpeg/video', 'error', faultText);

void main() {
  test(
    '0.6.1 log replay: moving software clock escaped old stall guard; new guard rebuilds once',
    () {
      // User log 04:24:05 hardware -> 04:24:17 dequeue failure -> software,
      // rising output drops despite 2.377/11.512/13.496 s of cached media.
      final old = RuntimeHealthWatch(), fixed = broken();
      final points = [
        frame(0, 985067, hw: 'mediacodec-copy'),
        frame(20, 989155),
        frame(30, 994869),
        frame(40, 1001167),
      ];
      for (final point in points) {
        expect(old.sample(point, speed: 1), RuntimeAction.none);
      }
      expect(fixed.sample(points[1]), HardwareRepairAction.retryHardware);
      expect(fixed.retried, isTrue);
      expect(
        fixed.sample(frame(22, 990000, hw: 'mediacodec-copy')),
        HardwareRepairAction.none,
      );
      expect(
        fixed.sample(frame(24, 992000, hw: 'mediacodec-copy')),
        HardwareRepairAction.verified,
      );
      expect(
        fixed.sample(frame(26, 994000, hw: 'mediacodec-copy')),
        HardwareRepairAction.none,
      );
    },
  );
  test(
    'software chosen at startup or missing property never forces hardware',
    () {
      for (final hw in ['no', '', 'unknown']) {
        final watch = HardwareFallbackWatch()..observeHardware(hw);
        expect(watch.fault('ffmpeg/video', 'error', faultText), false);
        expect(watch.sample(frame(1, 1000)), HardwareRepairAction.none);
      }
    },
  );
  test('one warning with healthy hardware never changes the decoder', () {
    final watch = broken();
    for (var i = 0; i < 8; i++) {
      expect(
        watch.sample(frame(13 + i, 1000 + i * 1000, hw: 'mediacodec-copy')),
        HardwareRepairAction.none,
      );
    }
    expect(watch.retried, false);
  });
  for (final (prefix, level, text) in [
    ('ffmpeg/audio', 'error', faultText),
    ('ffmpeg', 'error', 'HTTP 403 forbidden'),
    ('vd', 'warn', 'Surface changed'),
    ('ffmpeg/video', 'debug', faultText),
    ('ffmpeg/video', 'error', 'hevc: Could not find ref with POC 2'),
    ('vd', 'error', 'Could not open codec.'),
  ]) {
    test('unrelated $prefix/$level/$text cannot initiate hardware repair', () {
      final watch = HardwareFallbackWatch()..observeHardware('mediacodec-copy');
      expect(watch.fault(prefix, level, text), false);
      expect(watch.sample(frame(1, 1000)), HardwareRepairAction.none);
    });
  }
  test(
    'fixed MPV wrapper fallback spelling is recognized without exporting native text',
    () {
      expect(
        isRuntimeHardwareFailure(
          'vd',
          'warn',
          'Attempting next decoding method after failure of hevc_mediacodec-mediacodec-copy.\n',
        ),
        true,
      );
      expect(
        isRuntimeHardwareFailure(
          'vd',
          'warn',
          'Attempting next decoding method after failure of hevc-vaapi.',
        ),
        false,
      );
    },
  );
  test(
    'paused and seeking samples do not reset decoder or replenish budget',
    () {
      final watch = broken();
      expect(
        watch.sample(frame(14, 985067, playing: false)),
        HardwareRepairAction.none,
      );
      expect(
        watch.sample(frame(15, 985067, seeking: true)),
        HardwareRepairAction.none,
      );
      expect(
        watch.sample(frame(16, 985067)),
        HardwareRepairAction.retryHardware,
      );
      watch.cancel();
      expect(watch.retried, true);
      expect(watch.sample(frame(20, 1000)), HardwareRepairAction.none);
    },
  );
  test(
    'repeat hardware failure gets a single clean software seek, not a retry loop',
    () {
      final watch = broken();
      expect(
        watch.sample(frame(14, 985276)),
        HardwareRepairAction.retryHardware,
      );
      watch.fault('ffmpeg/video', 'error', faultText);
      expect(
        watch.sample(frame(16, 985276)),
        HardwareRepairAction.cleanSoftware,
      );
      for (var i = 17; i < 25; i++) {
        expect(watch.fault('ffmpeg/video', 'error', faultText), false);
      }
      expect(watch.sample(frame(26, 985276)), HardwareRepairAction.none);
      expect(watch.sample(frame(28, 987276)), HardwareRepairAction.verified);
      expect(watch.sample(frame(30, 989276)), HardwareRepairAction.none);
    },
  );
  test('quiet software fallback is cleaned only after two ready samples', () {
    final watch = broken();
    expect(watch.sample(frame(14, 985276)), HardwareRepairAction.retryHardware);
    expect(
      watch.sample(frame(15, 985276, output: false)),
      HardwareRepairAction.none,
    );
    expect(watch.sample(frame(16, 985276)), HardwareRepairAction.none);
    expect(watch.sample(frame(18, 985276)), HardwareRepairAction.cleanSoftware);
  });
  test('a pause longer than 30 seconds cannot erase an unresolved failure', () {
    final watch = broken();
    expect(
      watch.sample(frame(14, 985276, playing: false)),
      HardwareRepairAction.none,
    );
    expect(
      watch.sample(frame(120, 985276, playing: false)),
      HardwareRepairAction.none,
    );
    expect(
      watch.sample(frame(121, 985276)),
      HardwareRepairAction.retryHardware,
    );
  });
  test('fresh advancing hardware output clears an isolated old warning', () {
    final watch = broken();
    expect(
      watch.sample(frame(14, 985276, hw: 'mediacodec-copy')),
      HardwareRepairAction.none,
    );
    expect(
      watch.sample(frame(16, 987276, hw: 'mediacodec-copy')),
      HardwareRepairAction.none,
    );
    expect(watch.sample(frame(18, 988276)), HardwareRepairAction.none);
    expect(watch.retried, false);
  });
  test(
    'texture or advancing video without advancing audio is not recovery proof',
    () {
      final watch = broken();
      watch.sample(frame(14, 985276));
      expect(
        watch.sample(frame(16, 985276, hw: 'mediacodec-copy', audio: 985300)),
        HardwareRepairAction.none,
      );
      expect(
        watch.sample(frame(18, 987276, hw: 'mediacodec-copy', audio: 985300)),
        HardwareRepairAction.none,
      );
    },
  );
  test('intentional software stall recovery cancels old fault evidence', () {
    final watch = broken()..cancel();
    expect(watch.sample(frame(14, 985276)), HardwareRepairAction.none);
    watch.reset();
    expect(watch.hardware, isNull);
    expect(watch.retried, false);
  });
  test(
    'real repair commands keep position, rate, pause, tracks and URL untouched',
    () async {
      final calls = <String>[];
      await repairHardwareFallback(
        action: HardwareRepairAction.retryHardware,
        hardware: 'mediacodec-copy',
        position: const Duration(milliseconds: 985276),
        active: () => true,
        write: (k, v) async => calls.add('$k=$v'),
        seek: (v) async => calls.add('seek=${v.inMilliseconds}'),
      );
      expect(calls, ['hwdec=mediacodec-copy', 'seek=985276']);
      calls.clear();
      await repairHardwareFallback(
        action: HardwareRepairAction.cleanSoftware,
        hardware: 'mediacodec-copy',
        position: const Duration(milliseconds: 985276),
        active: () => true,
        write: (k, v) async => calls.add('$k=$v'),
        seek: (v) async => calls.add('seek=${v.inMilliseconds}'),
      );
      expect(calls, ['seek=985276']);
    },
  );
  test(
    'user seek, episode replacement or close cancels the stale checkpoint after async reset',
    () async {
      var live = true;
      final blocked = Completer<void>(), entered = Completer<void>();
      final calls = <String>[];
      final work = repairHardwareFallback(
        action: HardwareRepairAction.retryHardware,
        hardware: 'mediacodec-copy',
        position: const Duration(seconds: 985),
        active: () => live,
        write: (k, v) async {
          entered.complete();
          await blocked.future;
        },
        seek: (v) async => calls.add('seek'),
      );
      await entered.future;
      live = false;
      blocked.complete();
      await work;
      expect(calls, isEmpty);
    },
  );
  test(
    'native command rejection remains a failure and cannot seek or report success',
    () async {
      final calls = <String>[];
      await expectLater(
        repairHardwareFallback(
          action: HardwareRepairAction.retryHardware,
          hardware: 'mediacodec-copy',
          position: Duration.zero,
          active: () => true,
          write: (k, v) async => throw StateError('native rejected'),
          seek: (v) async => calls.add('seek'),
        ),
        throwsStateError,
      );
      expect(calls, isEmpty);
    },
  );
  test(
    'status and missing reference diagnostics retain facts without native private payload',
    () {
      final diag = VideoDiagnostics();
      expect(
        diag.add(
          'ffmpeg/video',
          'error',
          '$faultText https://secret.invalid/token',
        ),
        'ffmpeg/error：解码输出缓冲取出失败；状态码=-10000',
      );
      expect(
        diag.add(
          'ffmpeg/video',
          'error',
          'hevc: Could not find ref with POC 5 private',
        ),
        'ffmpeg/error：视频参考帧缺失',
      );
      expect(
        diag.add(
          'vd',
          'warn',
          'Attempting next decoding method after failure of hevc_mediacodec-mediacodec-copy.',
        ),
        'vd/warn：MediaCodec 失败，内核正切换后备解码',
      );
    },
  );
}
