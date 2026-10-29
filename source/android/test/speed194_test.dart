import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';
import 'host/pipeline194/metrics190.dart' as old;

void main() {
  test('all preexisting numeric stage messages retain complete190 output', () {
    for (final name in [
      'input_wait',
      'output_wait',
      'copy_api',
      'copy_drop',
      'get_buffer',
      'alloc_frame',
      'plane_copy',
      'release_output',
      'upload_api',
      'swap_api',
      'fence_api',
    ]) {
      for (final prefix in [
        'vd',
        'ffmpeg/video',
        'vo/gpu',
        'vo/gpu/opengl',
        'vo/gpu-next/opengl',
        'cplayer',
      ]) {
        for (var n = 0; n < 20; n++) {
          final row =
              'Yingyu stage136 name=$name window_us=2000000 calls=100 '
              'ok=90 total_us=${n * 10000} max_us=${n * 1000} serial=$n';
          expect(
            pipelineStageMessage(prefix, row),
            old.pipelineStageMessage(prefix, row),
          );
        }
      }
    }
  });
  test(
    'input work step is explicit, numeric, codec-only and not throughput',
    () {
      const row =
          'Yingyu stage136 name=input_step window_us=2000000 calls=100 '
          'ok=20 total_us=600000 max_us=8000 serial=3';
      final message = pipelineStageMessage('vd', row);
      expect(message, isNotNull);
      expect(message, contains('输入工作段'));
      expect(message, contains('预算触发输出查询'));
      expect(message, contains('非实际解码吞吐'));
      expect(pipelineStageMessage('vo/gpu', row), isNull);
      expect(pipelineStageMessage('vd', '$row\nprivate'), isNull);
      expect(
        pipelineStageMessage('vd', row.replaceFirst('ok=20', 'ok=101')),
        isNull,
      );
      expect(
        pipelineStageMessage(
          'vd',
          row.replaceFirst('input_step', 'input_unknown'),
        ),
        isNull,
      );
    },
  );
}
