import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'host/disc_pts084/backend.dart';

void missing(BackendHarness backend) => backend.packet(
  'ffmpeg/video',
  'warn',
  'hevc_mediacodec: Input packet is missing PTS',
);

void main() {
  const previous = bool.fromEnvironment('YINGYU_BACKEND084_OLD');
  for (final old in [previous]) {
    final label = old ? 'old' : 'new';
    BackendHarness create() =>
        old ? OldBackendHarness() : CurrentBackendHarness();

    for (final mode in ['copy', 'direct', 'raw', 'seek']) {
      test(
        '$label qualified disc missing PTS $mode uses one software recovery',
        () async {
          final backend = create()..start(speed: mode == 'direct' ? 2 : 1);
          if (mode == 'raw') {
            backend.packet(
              'ffmpeg/video',
              'warn',
              'Input packet is missing PTS',
            );
          } else {
            missing(backend);
          }
          if (mode == 'seek') backend.manualSeek(45);
          await backend.repair(
            mode == 'direct' ? 'mediacodec' : 'mediacodec-copy',
          );
          expect(backend.native.writes, [('hwdec', 'no')]);
          expect(backend.player.seeks, [
            Duration(seconds: mode == 'seek' ? 45 : 6),
          ]);
          expect(backend.recovering, true);
          expect(backend.logs.any((row) => row.contains('已记录缺失 PTS')), true);
          expect(backend.logs.any((row) => row.contains('核对通过')), false);
        },
      );
    }

    for (final mode in [
      'no-pts',
      'unselected',
      'ordinary',
      'dolby',
      'wrong-prefix',
      'verbose',
      'similar-text',
      'second-load',
    ]) {
      test('$label $mode retains the existing hardware rebuild', () async {
        final backend = create()
          ..start(
            disc: mode != 'ordinary',
            selected: mode != 'unselected',
            dolby: mode == 'dolby',
          );
        if (mode == 'second-load') {
          missing(backend);
          backend.start(serial: 2);
          missing(
            backend,
          ); // An untagged late native message cannot qualify it.
        } else if (mode == 'wrong-prefix') {
          backend.packet('ad', 'warn', 'Input packet is missing PTS');
        } else if (mode == 'verbose') {
          backend.packet(
            'ffmpeg/video',
            'debug',
            'Input packet is missing PTS',
          );
        } else if (mode == 'similar-text') {
          backend.packet(
            'ffmpeg/video',
            'warn',
            'Missing reference picture / PTS',
          );
        } else if (mode != 'no-pts') {
          missing(backend);
        }
        if (mode == 'unselected') backend.selectTimeline();
        await backend.repair('mediacodec-copy');
        expect(backend.native.writes, [('hwdec', 'mediacodec-copy')]);
        expect(backend.player.seeks, [const Duration(seconds: 6)]);
        expect(backend.logs.any((row) => row.contains('已记录缺失 PTS')), false);
      });
    }

    test('$label above 2x repair uses the intended decoder policy', () async {
      final backend = create()..start(speed: 3);
      await backend.repair('mediacodec-copy');
      expect(backend.native.writes, [
        ('hwdec', old ? 'no' : 'mediacodec-copy'),
      ]);
      expect(backend.player.seeks, [const Duration(seconds: 6)]);
    });

    test('$label manual software cannot trigger another runtime repair', () {
      final backend = create()..start();
      missing(backend);
      expect(backend.sample(now: 0, position: 6, audio: 6), RuntimeAction.none);
      expect(
        backend.sample(now: 6, position: 6, audio: 12),
        RuntimeAction.fail,
      );
      expect(backend.native.writes, isEmpty);
      expect(backend.attempted, false);
    });

    test(
      '$label new seek supersedes a queued recovery before native write',
      () async {
        final backend = create()..start();
        missing(backend);
        backend.beforeBuffer = () async => backend.manualSeek(45);
        await backend.repair('mediacodec-copy');
        expect(backend.native.writes, isEmpty);
        expect(backend.player.seeks, isEmpty);
        expect(backend.failure, isNull);
        expect(backend.recovering, false);
        expect(backend.attempted, true);
      },
    );

    test(
      '$label native write failure remains visible and does not seek',
      () async {
        final backend = create()..start();
        backend.native.failWrite = true;
        await backend.repair('mediacodec-copy');
        expect(backend.failure, contains('解码恢复命令失败'));
        expect(backend.player.seeks, isEmpty);
        expect(backend.logs.any((row) => row.contains('命令已完成')), false);
      },
    );

    test(
      '$label expected software needs actual advancing software audio and video',
      () async {
        final backend = create()..start();
        missing(backend);
        await backend.repair('mediacodec-copy');
        expect(
          backend.sample(now: 1, position: 6, audio: 6),
          RuntimeAction.none,
        );
        expect(
          backend.sample(now: 3, position: 7, audio: 7),
          RuntimeAction.none,
        );
        expect(
          backend.sample(now: 5, position: 9, audio: 9),
          RuntimeAction.recovered,
        );
        expect(backend.attempted, true);
        expect(
          backend.sample(now: 7, position: 9, audio: 9),
          RuntimeAction.none,
        );
        expect(
          backend.sample(now: 13, position: 9, audio: 15),
          RuntimeAction.fail,
        );
        expect(backend.native.writes.length, 1);
      },
    );

    test(
      '$label accepted software write with actual hardware never confirms and times out',
      () async {
        final backend = create()..start();
        missing(backend);
        await backend.repair('mediacodec-copy');
        expect(
          backend.sample(
            now: 1,
            position: 6,
            audio: 6,
            hardware: 'mediacodec-copy',
          ),
          RuntimeAction.none,
        );
        expect(
          backend.sample(
            now: 3,
            position: 7,
            audio: 7,
            hardware: 'mediacodec-copy',
          ),
          RuntimeAction.none,
        );
        expect(
          backend.sample(
            now: 31,
            position: 8,
            audio: 40,
            hardware: 'mediacodec-copy',
          ),
          RuntimeAction.fail,
        );
      },
    );

    test(
      '$label missing decoder property is unknown and never confirms software',
      () async {
        final backend = create()..start();
        missing(backend);
        await backend.repair('mediacodec-copy');
        expect(
          backend.sample(now: 1, position: 6, audio: 6, hardware: ''),
          RuntimeAction.none,
        );
        expect(
          backend.sample(now: 3, position: 7, audio: 7, hardware: ''),
          RuntimeAction.none,
        );
        expect(
          backend.sample(now: 31, position: 8, audio: 40, hardware: ''),
          RuntimeAction.fail,
        );
      },
    );
  }

  if (!previous) {
    test(
      'new fixture contains the complete current production methods verbatim',
      () {
        final source = File(
          'lib/playback/backend.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n');
        final fixture = File(
          'test/host/disc_pts084/backend.dart',
        ).readAsStringSync().replaceAll('\r\n', '\n');
        for (final markers in [
          (
            '  void _beginDiscTimestampScope(',
            '  Future<void> _repairRuntimeVideo(',
          ),
          (
            '  Future<void> _repairRuntimeVideo(',
            '  Future<void> _repairHardwareFallback(',
          ),
        ]) {
          final start = source.indexOf(markers.$1);
          final method = source
              .substring(
                start,
                source.indexOf(markers.$2, start + markers.$1.length),
              )
              .trimRight();
          expect(fixture, contains(method));
        }
        expect(
          source,
          contains(
            '_observeDiscPacketTimestamp(log.prefix, log.level, log.text);',
          ),
        );
        expect(
          source,
          contains(
            'final serial = ++_loadSerial;\n        _beginDiscTimestampScope(serial);',
          ),
        );
        expect(
          source,
          contains(
            '_runtimeWatch.reset();\n    _videoLoss.reset();\n    _discClockFault.clear();\n    _discPtsLoad = null;\n    _discMissingVideoPts = false;',
          ),
        );
      },
    );
  }
}
