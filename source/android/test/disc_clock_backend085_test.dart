import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'host/disc_clock085/old/backend.dart' as previous;
import 'host/disc_clock085/new/backend.dart' as current;

void main() {
  const old = bool.fromEnvironment('YINGYU_BACKEND085_OLD');
  final label = old ? 'old' : 'new';
  dynamic create({
    int serial = 1,
    bool disc = true,
    bool dolby = false,
    double speed = 1,
  }) {
    final dynamic backend = old
        ? previous.BackendHarness()
        : current.BackendHarness();
    backend.start(serial: serial, disc: disc, dolby: dolby, speed: speed);
    return backend;
  }

  Future<void> trace(dynamic backend, {String mode = 'actual'}) async {
    if (mode != 'no-baseline') {
      await backend.probeAt(9592, 1440.188744, 1440.188729, buffering: true);
    }
    backend.checkpoint(1441.106);
    for (final ms in [11591, 13590, 15590, 17590, 19590]) {
      await backend.probeAt(
        ms,
        mode == 'jitter' ? 1440.15 : 0.0,
        mode == 'unknown-audio' ? null : 1442.002 + (ms - 11591) / 1000,
        buffering: mode == 'buffering',
        seeking: mode == 'native-seek',
        nativePosition: mode == 'unknown-position'
            ? 'unavailable'
            : mode == 'nan-position'
            ? 'nan'
            : null,
      );
    }
  }

  for (final serial in [1, 3]) {
    test(
      '$label actual 084 synchronized output then zero uses one software seek load$serial',
      () async {
        final backend = create(serial: serial);
        await trace(backend);
        expect(backend.native.writes, [('hwdec', 'no')]);
        expect(backend.player.seeks, [const Duration(milliseconds: 1441106)]);
        expect(
          backend.logs.any((String s) => s.contains('同步输出后无定位持续回零')),
          isTrue,
        );
        expect(backend.attempted, isTrue);
        expect(backend.recovering, isTrue);
      },
    );
  }
  for (final mode in [
    'ordinary',
    'dolby',
    'no-baseline',
    'unknown-audio',
    'unknown-position',
    'nan-position',
    'jitter',
    'buffering',
    'native-seek',
  ]) {
    test('$label $mode does not earn the new disc fallback', () async {
      final backend = create(disc: mode != 'ordinary', dolby: mode == 'dolby');
      await trace(backend, mode: mode);
      expect(
        backend.native.writes.every((dynamic row) => row.$2 != 'no'),
        isTrue,
      );
    });
  }
  test(
    '$label actual fallback needs continuous synchronized software output',
    () async {
      final backend = create();
      await trace(backend);
      await backend.probeAt(21590, 1441.2, 1441.2, hardware: 'no');
      expect(backend.recovering, isTrue);
      await backend.probeAt(23590, 1443.2, 1443.2, hardware: 'no');
      expect(backend.recovering, isTrue);
      await backend.probeAt(25590, 1445.2, 1445.2, hardware: 'no');
      expect(backend.recovering, isFalse);
      expect(backend.failure, isNull);
      expect(backend.native.writes, [('hwdec', 'no')]);
    },
  );
  for (final mode in [
    'large-drift',
    'both-slow',
    'still-hardware',
    'unknown-decoder',
  ]) {
    test(
      '$label $mode cannot masquerade as special software recovery',
      () async {
        final backend = create();
        await trace(backend);
        for (var index = 0; index <= 16; index++) {
          final elapsed = index * 2.0;
          final video = mode == 'both-slow' || mode == 'large-drift'
              ? 1441.2 + elapsed * .1
              : 1441.2 + elapsed;
          final audio = mode == 'large-drift' ? 1441.2 + elapsed : video;
          await backend.probeAt(
            21590 + index * 2000,
            video,
            audio,
            hardware: mode == 'still-hardware'
                ? 'mediacodec-copy'
                : mode == 'unknown-decoder'
                ? ''
                : 'no',
          );
        }
        expect(backend.failure, contains('本次恢复未成功'));
        expect(backend.logs.any((String s) => s.contains('视频恢复核对通过')), isFalse);
        expect(backend.native.writes.length, 1);
      },
    );
  }
  test(
    '$label explicit seek discards the old regression and preserves attempt budget',
    () async {
      final backend = create();
      await backend.probeAt(9592, 1440.188, 1440.188, buffering: true);
      await backend.seek(const Duration(seconds: 45));
      for (final ms in [11591, 13590, 15590, 17590, 19590]) {
        await backend.probeAt(ms, 0.0, 50 + (ms - 11591) / 1000);
      }
      expect(
        backend.native.writes.every((dynamic row) => row.$2 != 'no'),
        isTrue,
      );
    },
  );
  test(
    '$label late probe across new load cannot qualify or trigger recovery',
    () async {
      final backend = create();
      final entered = Completer<void>(), release = Completer<void>();
      var first = true;
      backend.native.beforeRead = (String key) async {
        if (first) {
          first = false;
          entered.complete();
          await release.future;
        }
      };
      final pending = backend.probeAt(
        9592,
        1440.188,
        1440.188,
        buffering: true,
      );
      await entered.future;
      backend.start(serial: 3);
      release.complete();
      await pending;
      backend.native.beforeRead = null;
      for (final ms in [11591, 13590, 15590, 17590, 19590]) {
        await backend.probeAt(ms, 0.0, 1442 + (ms - 11591) / 1000);
      }
      expect(
        backend.native.writes.every((dynamic row) => row.$2 != 'no'),
        isTrue,
      );
    },
  );
  test('$label original missing PTS first-load fallback remains', () async {
    final backend = create();
    backend.checkpoint(6.0);
    backend.packet(
      'ffmpeg/video',
      'warn',
      'h264_mediacodec: Input packet is missing PTS',
    );
    await backend.repair('mediacodec-copy');
    expect(backend.native.writes, [('hwdec', 'no')]);
    expect(backend.player.seeks, [const Duration(seconds: 6)]);
  });
  for (final mode in ['large-drift', 'both-slow']) {
    test(
      '$label original PTS software $mode must not falsely confirm',
      () async {
        final backend = create();
        backend.checkpoint(6.0);
        backend.packet('ffmpeg/video', 'warn', 'Input packet is missing PTS');
        await backend.repair('mediacodec-copy');
        for (var index = 0; index <= 16; index++) {
          final elapsed = index * 2.0;
          await backend.probeAt(
            1000 + index * 2000,
            6.0 + elapsed * .1,
            6.0 + elapsed * (mode == 'large-drift' ? 1 : .1),
            hardware: 'no',
          );
        }
        expect(backend.logs.any((String s) => s.contains('视频恢复核对通过')), isFalse);
        expect(backend.failure, contains('本次恢复未成功'));
      },
    );
  }
  for (final mode in ['pause', 'buffer', 'seek']) {
    test(
      '$label queued $mode cancels a new clock recovery before native mutation',
      () async {
        final backend = create();
        final release = Completer<void>();
        final blocked = backend.blockQueue(release.future);
        await trace(backend);
        Future<void>? seek;
        if (mode == 'pause') backend.setPlaying(false);
        if (mode == 'buffer') backend.setBuffering(true);
        if (mode == 'seek') seek = backend.seek(const Duration(seconds: 45));
        release.complete();
        await blocked;
        if (seek != null) await seek;
        await Future<void>.delayed(Duration.zero);
        expect(backend.native.writes, isEmpty);
        expect(backend.logs.any((String s) => s.contains('视频停滞恢复开始')), isFalse);
      },
    );
  }
  test(
    '$label another probe during a short queued recovery preserves clock evidence',
    () async {
      final backend = create();
      final release = Completer<void>();
      final blocked = backend.blockQueue(release.future);
      await trace(backend);
      await backend.probeAt(21590, 0.0, 1452.002);
      release.complete();
      await blocked;
      await Future<void>.delayed(Duration.zero);
      expect(backend.native.writes, [('hwdec', 'no')]);
      expect(backend.player.seeks, [const Duration(milliseconds: 1441106)]);
    },
  );
  test(
    '$label autonomous synchronized recovery cancels a queued clock repair',
    () async {
      final backend = create();
      final release = Completer<void>();
      final blocked = backend.blockQueue(release.future);
      await trace(backend);
      await backend.probeAt(21590, 1452.002, 1452.002);
      release.complete();
      await blocked;
      await Future<void>.delayed(Duration.zero);
      expect(backend.native.writes, isEmpty);
      expect(backend.player.seeks, isEmpty);
      expect(backend.logs.any((String s) => s.contains('视频停滞恢复开始')), isFalse);
    },
  );
  test(
    '$label extracted sampler scope recovery and seek are verbatim production methods',
    () {
      final source = File(
        old
            ? 'test/host/disc_clock085/old/backend-production.txt'
            : 'lib/playback/backend.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final fixture = File(
        'test/host/disc_clock085/${old ? 'old' : 'new'}/backend.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      for (final markers in [
        (
          '  Future<void> _recordVideoHealth()',
          '  void _beginDiscTimestampScope(',
        ),
        (
          '  void _beginDiscTimestampScope(',
          '  Future<void> _repairRuntimeVideo(',
        ),
        (
          '  Future<void> _repairRuntimeVideo(',
          '  Future<void> _repairHardwareFallback(',
        ),
        (
          '  @override\n  Future<void> seek(Duration position)',
          '  @override\n  Future<void> rate(double value)',
        ),
        ('  Future<void> _applyRate(double value)', '  void _retainDiscCache('),
      ]) {
        final start = source.indexOf(markers.$1);
        expect(
          fixture.contains(
            source
                .substring(
                  start,
                  source.indexOf(markers.$2, start + markers.$1.length),
                )
                .trimRight(),
          ),
          isTrue,
          reason: markers.$1,
        );
      }
    },
  );
  for (final mode in ['initial-three-to-one', 'one-three-one-between-probes']) {
    test(
      '$label confirmed rate history $mode preserves valid software recovery',
      () async {
        final backend = create(
          speed: mode == 'initial-three-to-one' ? 3.0 : 1.0,
        );
        backend.checkpoint(6.0);
        backend.packet('ffmpeg/video', 'warn', 'Input packet is missing PTS');
        await backend.repair('mediacodec-copy');
        backend.positionEvent(6.0);
        if (mode == 'initial-three-to-one') {
          await backend.confirmRate(1.0, 2000);
          await backend.probeAt(4000, 14.0, 14.0, hardware: 'no');
          await backend.probeAt(6000, 16.0, 16.0, hardware: 'no');
          await backend.probeAt(8000, 18.0, 18.0, hardware: 'no');
        } else {
          await backend.probeAt(1000, 7.0, 7.0, hardware: 'no');
          await backend.confirmRate(3.0, 2000);
          await backend.confirmRate(1.0, 3000);
          await backend.probeAt(4000, 12.0, 12.0, hardware: 'no');
          await backend.probeAt(6000, 14.0, 14.0, hardware: 'no');
          await backend.probeAt(8000, 16.0, 16.0, hardware: 'no');
        }
        expect(backend.recovering, isFalse);
        expect(backend.failure, isNull);
        expect(backend.logs.any((String s) => s.contains('视频恢复核对通过')), isTrue);
      },
    );
  }
  test(
    '$label failed desired rate cannot widen the strict recovery upper bound',
    () async {
      final backend = create();
      backend.checkpoint(6.0);
      backend.packet('ffmpeg/video', 'warn', 'Input packet is missing PTS');
      await backend.repair('mediacodec-copy');
      backend.positionEvent(6.0);
      backend.player.failRate = true;
      await expectLater(backend.confirmRate(3.0, 1000), throwsStateError);
      backend.player.failRate = false;
      for (var ms = 4000; ms <= 36000; ms += 2000) {
        final position = 14.0 + (ms - 4000) / 1000;
        await backend.probeAt(ms, position, position, hardware: 'no');
      }
      expect(backend.logs.any((String s) => s.contains('视频恢复核对通过')), isFalse);
      expect(backend.failure, contains('本次恢复未成功'));
    },
  );
}
