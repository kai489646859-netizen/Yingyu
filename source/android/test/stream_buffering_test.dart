import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/stream_buffering.dart';
import 'package:yingyu/playback/disc_buffer_phase.dart';
import 'package:yingyu/playback/disc_buffering.dart';

void main() {
  for (final speed in [.5, 1.0, 1.5, 2.0, 3.0]) {
    test(
      'ordinary stream at $speed opens/seeks fast then restores its cushion',
      () async {
        final writes = <String>[];
        final buffer = StreamBuffering(
          write: (key, value) async => writes.add('$key=$value'),
          onRestoreFailure: () => fail('unexpected rollback failure'),
        );
        final phase = DiscBufferPhase();
        for (var seek = 0; seek < 3; seek++) {
          phase.begin();
          await buffer.configure(speed, fast: phase.fast);
          expect(buffer.applied, '1.00');
          phase.arm();
          expect(
            phase.canPromote(
              sampleEpoch: phase.epoch,
              outputReady: true,
              buffering: false,
              cachePaused: false,
              seeking: false,
            ),
            false,
          );
          phase.restart();
          expect(
            phase.canPromote(
              sampleEpoch: phase.epoch,
              outputReady: true,
              buffering: true,
              cachePaused: true,
              seeking: false,
            ),
            false,
          );
          expect(
            phase.canPromote(
              sampleEpoch: phase.epoch,
              outputReady: true,
              buffering: false,
              cachePaused: false,
              seeking: false,
            ),
            true,
          );
          phase.complete(phase.epoch);
          await buffer.configure(speed, fast: phase.fast);
          expect(
            double.parse(buffer.applied!),
            speed <= 1
                ? 1
                : speed <= 2
                ? speed * 4
                : speed * 8,
          );
        }
        // No reader/reopen/byte-limit/decoder command can be issued by this policy.
        expect(
          writes.every(
            (v) =>
                v.startsWith('cache-pause-wait=') ||
                v.startsWith('cache-secs=') ||
                v.startsWith('demuxer-max-bytes='),
          ),
          true,
        );
      },
    );
  }
  test(
    'rapid held 3x then 2x/1x changes lower the actual gate immediately',
    () async {
      final writes = <String>[];
      final buffer = StreamBuffering(
        write: (k, v) async {
          if (k == 'cache-pause-wait') writes.add(v);
        },
        onRestoreFailure: () => fail('rollback'),
      );
      final queue = PlaybackRateQueue(
        (speed) => buffer.configure(speed, fast: false),
      );
      await Future.wait([queue.set(3), queue.set(2), queue.set(1)]);
      expect(writes, ['24.00', '8.00', '1.00']);
    },
  );
  test(
    'partial property failure restores the previous gate; next change still works',
    () async {
      var actual = '1.00', failures = 0;
      final buffer = StreamBuffering(
        write: (k, v) async {
          if (k == 'cache-pause-wait') actual = v;
          if (v == '24.00') {
            throw StateError('synthetic native failure after write');
          }
        },
        onRestoreFailure: () => failures++,
      );
      await buffer.configure(2, fast: false);
      await expectLater(buffer.configure(3, fast: false), throwsStateError);
      expect(actual, '8.00');
      expect(buffer.applied, '8.00');
      expect(failures, 0);
      await buffer.configure(1, fast: false);
      expect(actual, '1.00');
    },
  );
  test(
    'failed native speed command can restore the prior cache gate',
    () async {
      final writes = <String>[];
      final buffer = StreamBuffering(
        write: (k, v) async {
          if (k == 'cache-pause-wait') writes.add(v);
        },
        onRestoreFailure: () => fail('rollback'),
      );
      await buffer.configure(2, fast: false);
      final before = buffer.applied;
      await buffer.configure(3, fast: false);
      await buffer.restore(before);
      expect(writes, ['8.00', '24.00', '8.00']);
    },
  );
  test(
    'rollback failure is reported rather than pretending parameters restored',
    () async {
      var errors = 0;
      final buffer = StreamBuffering(
        write: (k, v) async => throw StateError('synthetic native failure'),
        onRestoreFailure: () => errors++,
      );
      await expectLater(buffer.configure(2, fast: false), throwsStateError);
      expect(errors, 1);
      expect(buffer.applied, isNull);
    },
  );
}
