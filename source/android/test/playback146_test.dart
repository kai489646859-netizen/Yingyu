import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/stream_buffering.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';
import 'host/playback146/old145_stream_buffering.dart' as old;
import 'host/playback142/rebuffer.dart' as actual;
import 'host/playback146/old145_pipeline_metrics.dart' as old_log;

void main() {
  test(
    'complete production scheduler counts separated runtime underruns',
    () async {
      final h = actual.Harness();
      await h.start();
      h.runtime();
      h.event();
      await h.flush();
      expect(h.values['cache-pause-wait'], '2.00');
      h.event();
      await h.flush();
      expect(h.values['cache-pause-wait'], '2.00');
      h.event(buffering: false);
      h.event();
      await h.flush();
      expect(h.values['cache-pause-wait'], '4.00');
    },
  );

  test(
    'preserves recovery across same-media seek but resets a new opening',
    () async {
      final before = old.StreamBuffering(
        write: (k, v) async {},
        onRestoreFailure: () => fail('old rollback'),
      );
      final current = StreamBuffering(
        write: (k, v) async {},
        onRestoreFailure: () => fail('rollback'),
      );
      await before.configure(1, fast: true);
      await current.configure(1, fast: true);
      expect(current.applied, before.applied);
      await before.markStarved(1, fast: false);
      await current.markStarved(1, fast: false);
      before.beginFast();
      current.beginFast(preserveRecovery: true);
      await before.configure(1, fast: true);
      await current.configure(1, fast: true);
      expect(before.applied, '1.00'); // complete145 loses its learned cushion
      expect(current.applied, '2.00');
      current.beginFast();
      await current.configure(1, fast: true);
      expect(current.applied, '1.00');
    },
  );

  test(
    'repeated actual underruns increase only bounded recovery, not opening',
    () async {
      final values = <String, String>{};
      final buffer = StreamBuffering(
        write: (k, v) async => values[k] = v,
        onRestoreFailure: () => fail('rollback'),
      );
      await buffer.configure(1, fast: true);
      expect(buffer.applied, '1.00');
      await buffer.markStarved(1, fast: false);
      expect(buffer.applied, '2.00');
      for (var i = 0; i < 10; i++) {
        await buffer.markStarved(1, fast: false);
      }
      expect(
        buffer.applied,
        '2.00',
      ); // duplicate true notifications are one event
      buffer.endStarvation();
      await buffer.markStarved(1, fast: false);
      expect(buffer.applied, '4.00');
      expect(values['cache-secs'], '60');
      expect(buffer.snapshot.bytes, 64 * 1024 * 1024);
      for (var i = 0; i < 10; i++) {
        buffer.endStarvation();
        await buffer.markStarved(1, fast: false);
      }
      expect(buffer.applied, '4.00');
      await buffer.configure(2, fast: false);
      expect(buffer.applied, '8.00');
      await buffer.configure(3, fast: false);
      expect(buffer.applied, '24.00');
      buffer.beginFast();
      await buffer.configure(1, fast: true);
      expect(buffer.applied, '1.00');
    },
  );

  test(
    'failed repeated-starvation write rolls back state and allows retry',
    () async {
      var reject = false;
      final values = <String, String>{};
      final buffer = StreamBuffering(
        write: (k, v) async {
          values[k] = v;
          if (reject && k == 'cache-pause-wait' && v == '4.00') {
            throw StateError('injected after mutation');
          }
        },
        onRestoreFailure: () => fail('rollback'),
      );
      await buffer.configure(1, fast: false);
      await buffer.markStarved(1, fast: false);
      buffer.endStarvation();
      reject = true;
      await expectLater(buffer.markStarved(1, fast: false), throwsStateError);
      expect(buffer.applied, '2.00');
      expect(values['cache-pause-wait'], '2.00');
      reject = false;
      await buffer.markStarved(1, fast: false);
      expect(buffer.applied, '4.00');
    },
  );

  test(
    'parses actual FFmpeg item-name prefixes without accepting arbitrary text',
    () {
      const nonref = 'hevc_mediacodec: Yingyu nonref145 packets=127';
      const body =
          'http: Yingyu body144 window_us=2000000 calls=10 ok=10 '
          'total_us=1900000 max_us=1500000 bytes=2000000 epoch=2';
      expect(old_log.pipelineStageMessage('ffmpeg/video', nonref), isNull);
      expect(old_log.pipelineStageMessage('ffmpeg', body), isNull);
      expect(pipelineStageMessage('ffmpeg/video', nonref), contains('127'));
      expect(pipelineStageMessage('ffmpeg', body), contains('媒体正文读取核对'));
      expect(
        pipelineStageMessage('ffmpeg', body.replaceFirst('http:', 'https:')),
        contains('媒体正文读取核对'),
      );
      expect(pipelineStageMessage('ffmpeg', 'private: $body'), isNull);
      expect(pipelineStageMessage('ffmpeg/video', '$nonref secret'), isNull);
    },
  );
}
