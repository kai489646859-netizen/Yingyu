import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

void main() {
  test(
    'counts native nonreference omissions without claiming presentation',
    () {
      final text = pipelineStageMessage(
        'ffmpeg/video',
        'Yingyu nonref145 packets=153',
      );
      expect(text, contains('累计跳过=153'));
      expect(text, contains('不是实际呈现帧率'));
    },
  );

  test('rejects wrong source and untrusted numeric report suffixes', () {
    for (final prefix in ['vd', 'ffmpeg', 'vo/gpu']) {
      expect(
        pipelineStageMessage(prefix, 'Yingyu nonref145 packets=1'),
        isNull,
      );
    }
    for (final value in ['0', '-1', '1 trailing', 'https://secret', '9' * 19]) {
      expect(
        pipelineStageMessage('ffmpeg/video', 'Yingyu nonref145 packets=$value'),
        isNull,
      );
    }
  });
}
