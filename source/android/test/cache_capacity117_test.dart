import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/cache_policy.dart';
import 'package:yingyu/playback/disc_buffer_phase.dart';
import 'package:yingyu/playback/stream_buffering.dart';

void main() {
  const mib = 1024 * 1024;
  test(
    '2x and 3x enlarge both media window and actual ordinary packet limit',
    () async {
      final actual = <String, String>{'demuxer-max-bytes': '${64 * mib}'};
      final buffer = StreamBuffering(
        write: (k, v) async => actual[k] = v,
        onRestoreFailure: () => fail('restore'),
      );
      await buffer.configure(2, fast: false);
      expect(actual['cache-secs'], '120');
      expect(actual['demuxer-max-bytes'], '${192 * mib}');
      expect(actual['cache-pause-wait'], '8.00');
      await buffer.configure(3, fast: false);
      expect(actual['cache-secs'], '180');
      expect(actual['demuxer-max-bytes'], '${384 * mib}');
      expect(actual['cache-pause-wait'], '24.00');
      await buffer.configure(1, fast: true);
      expect(actual['cache-secs'], '10');
      expect(actual['demuxer-max-bytes'], '${64 * mib}');
      expect(actual['cache-pause-wait'], '1.00');
    },
  );
  test('disc budget grows at both speeds while retaining fast-seek limits', () {
    DiscBufferPlan plan(double speed, {bool fast = false}) => DiscBufferPlan(
      speed: speed,
      fast: fast,
      baseBytes: 128 * mib,
      memoryMiB: 128,
    );
    expect(plan(2).bytes, 384 * mib);
    expect(plan(3).bytes, 768 * mib);
    expect(plan(3, fast: true).bytes, 128 * mib);
    final ahead = PlaybackReadAhead()..speed(2);
    expect(ahead.seconds, 600);
    ahead.speed(3);
    expect(ahead.seconds, 1200);
  });
  for (final key in ['cache-secs', 'demuxer-max-bytes', 'cache-pause-wait']) {
    test(
      'partial failure at $key restores all native cache properties',
      () async {
        final actual = <String, String>{};
        var armed = false, failed = false, restoreFailures = 0;
        final buffer = StreamBuffering(
          write: (k, v) async {
            actual[k] = v;
            if (armed && !failed && k == key) {
              failed = true;
              throw StateError('mutated before failing');
            }
          },
          onRestoreFailure: () => restoreFailures++,
        );
        await buffer.configure(1, fast: true);
        actual['demuxer-max-bytes'] = '${64 * mib}';
        final before = Map.of(actual);
        armed = true;
        await expectLater(buffer.configure(3, fast: false), throwsStateError);
        expect(failed, true);
        expect(actual, before);
        expect(restoreFailures, 0);
      },
    );
  }
  test(
    'failed speed command restores snapshot; low memory remains bounded',
    () async {
      final actual = <String, String>{};
      final buffer = StreamBuffering(
        write: (k, v) async => actual[k] = v,
        baseBytes: 32 * mib,
        memoryMiB: 32,
        onRestoreFailure: () => fail('restore'),
      );
      await buffer.configure(2, fast: false);
      expect(actual['demuxer-max-bytes'] ?? '${32 * mib}', '${32 * mib}');
      final snapshot = buffer.snapshot;
      final before = Map.of(actual);
      await buffer.configure(3, fast: false);
      await buffer.restoreSnapshot(snapshot);
      expect(actual, before);
      expect(actual['cache-pause-wait'], '8.00');
    },
  );
}
