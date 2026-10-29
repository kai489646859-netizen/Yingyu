import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

void main() {
  test(
    'release observations preserve actual capacity and unavailable state',
    () {
      expect(
        pipelineStageMessage(
          'ffmpeg/video',
          'hevc_mediacodec: Yingyu release153 active=1 capacity=4',
        ),
        contains('最多持有4个编号'),
      );
      expect(
        pipelineStageMessage(
          'ffmpeg/video',
          'Yingyu release147 active=1 capacity=2',
        ),
        contains('最多持有2个编号'),
      );
      expect(
        pipelineStageMessage(
          'ffmpeg/video',
          'Yingyu release153 active=0 capacity=4',
        ),
        contains('保留原同步路径'),
      );
      for (final input in [
        'Yingyu release153 active=1 capacity=2',
        'Yingyu release147 active=1 capacity=4',
        'Yingyu release153 active=1 capacity=8',
        'Yingyu release153 active=1 capacity=4 private-data',
      ]) {
        expect(pipelineStageMessage('ffmpeg/video', input), isNull);
      }
      expect(
        pipelineStageMessage('vo/gpu', 'Yingyu release153 active=1 capacity=4'),
        isNull,
      );
    },
  );
}
