import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/stream_buffering.dart';
import 'package:yingyu/playback/cache_policy.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';
import 'dart:async';
import 'host/playback142/rebuffer.dart' as actual;
import 'host/playback142/old/stream_buffering.dart' as old;

void main() {
  test(
    'same hold/release sequence against complete delivered141 class',
    () async {
      final before = <String, String>{}, after = <String, String>{};
      final previous = old.StreamBuffering(
        baseBytes: 128 * 1024 * 1024,
        memoryMiB: 128,
        write: (k, v) async {
          before[k] = v;
        },
        onRestoreFailure: () => fail('old restore'),
      );
      final current = StreamBuffering(
        baseBytes: 128 * 1024 * 1024,
        memoryMiB: 128,
        write: (k, v) async {
          after[k] = v;
        },
        onRestoreFailure: () => fail('current restore'),
      );
      for (final value in [1.0, 3.0, 1.0, 2.0]) {
        await previous.configure(value, fast: false);
        await current.configure(value, fast: false);
      }
      expect(before['cache-secs'], '1200');
      expect(after['cache-secs'], '120');
      expect(before['demuxer-max-bytes'], '${768 * 1024 * 1024}');
      expect(after['demuxer-max-bytes'], '${384 * 1024 * 1024}');
    },
  );
  test(
    'actual starvation scheduler excludes opening, pause, disc and stale work',
    () async {
      for (var n = 0; n < 8; n++) {
        final h = actual.Harness();
        await h.start();
        final signal = Completer<void>();
        final waiting = h.block(signal.future);
        if (n == 0) h.opening = true;
        if (n == 1) h.player.state.playing = false;
        if (n == 2) h.disc = Object();
        if (n == 3) h.network = false;
        h.event();
        if (n == 4) h.seek();
        if (n == 5) h.replace();
        if (n == 6) h.disposed = true;
        if (n == 7) h.player.state.buffering = false;
        signal.complete();
        await waiting;
        await h.flush();
        expect(h.values['cache-pause-wait'], '1.00', reason: 'guard $n');
      }
      final h = actual.Harness();
      await h.start();
      h.event();
      await h.flush();
      expect(h.values['cache-pause-wait'], '2.00');
    },
  );
  test(
    'brief held 3x releases the ordinary prefetch budget on return',
    () async {
      final values = <String, String>{};
      final buffer = StreamBuffering(
        baseBytes: 128 * 1024 * 1024,
        memoryMiB: 128,
        write: (key, value) async => values[key] = value,
        onRestoreFailure: () => fail('restore failed'),
      );
      await buffer.configure(1, fast: true);
      expect(values['cache-pause-wait'], '1.00');
      expect(values['cache-secs'], '10');
      await buffer.configure(1, fast: false);
      await buffer.configure(3, fast: false);
      await buffer.configure(1, fast: false);
      expect(values['cache-secs'], '60');
      expect(values['demuxer-max-bytes'], '${128 * 1024 * 1024}');
      await buffer.configure(2, fast: false);
      expect(values['cache-secs'], '120');
      expect(values['demuxer-max-bytes'], '${384 * 1024 * 1024}');
    },
  );
  test(
    'first playback stays fast; only an actual starvation raises recovery',
    () async {
      final values = <String, String>{};
      final buffer = StreamBuffering(
        write: (k, v) async => values[k] = v,
        onRestoreFailure: () => fail('restore'),
      );
      await buffer.configure(1, fast: true);
      expect(buffer.applied, '1.00');
      await buffer.markStarved(1, fast: true);
      expect(buffer.applied, '2.00');
      expect(values['cache-secs'], '10');
      await buffer.configure(1, fast: false);
      expect(buffer.applied, '2.00');
      await buffer.configure(2, fast: false);
      expect(buffer.applied, '8.00');
      buffer.beginFast();
      await buffer.configure(1, fast: true);
      expect(buffer.applied, '1.00');
    },
  );
  test('ordinary prefetch follows actual rate while disc retains its peak', () {
    final ordinary = PlaybackReadAhead(), disc = PlaybackReadAhead();
    for (final speed in [1.0, 3.0, 1.0, 2.0]) {
      ordinary.speed(speed, retainPeak: false);
      disc.speed(speed);
    }
    expect(ordinary.seconds, 120);
    expect(disc.seconds, 1200);
  });
  test('starvation write failure restores original buffer state', () async {
    final values = <String, String>{};
    var reject = false;
    final buffer = StreamBuffering(
      write: (k, v) async {
        values[k] = v;
        if (reject && k == 'cache-pause-wait' && v == '2.00') {
          throw StateError('injected');
        }
      },
      onRestoreFailure: () => fail('rollback'),
    );
    await buffer.configure(1, fast: true);
    reject = true;
    await expectLater(buffer.markStarved(1, fast: true), throwsStateError);
    expect(buffer.applied, '1.00');
    expect(values['cache-pause-wait'], '1.00');
  });
  test('worker diagnostics admit only fixed numeric native messages', () {
    expect(
      pipelineStageMessage('vd', 'Yingyu copy142 queue samples=6'),
      contains('6 帧'),
    );
    expect(
      pipelineStageMessage('vd', 'Yingyu copy142 queue samples=99'),
      isNull,
    );
    expect(
      pipelineStageMessage('http', 'Yingyu copy142 queue samples=6'),
      isNull,
    );
    expect(
      pipelineStageMessage('vd', 'Yingyu copy142 queue samples=6 /secret'),
      isNull,
    );
  });
}
