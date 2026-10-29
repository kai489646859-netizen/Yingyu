import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

void main() {
  test('restored164 ignores the retired ready166 confirmation', () {
    const row = 'Yingyu ready166 active=1';
    expect(pipelineStageMessage('vd', row), isNull);
    for (final prefix in ['cplayer', 'ffmpeg/video', 'vo/gpu']) {
      expect(pipelineStageMessage(prefix, row), isNull);
    }
    for (final text in [
      '$row private-token',
      '$row\nextra',
      'Yingyu ready166 active=0',
      'Yingyu ready166 active=01',
    ]) {
      expect(pipelineStageMessage('vd', text), isNull);
    }
  });
}
