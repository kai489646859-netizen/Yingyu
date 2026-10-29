import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/cache_policy.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

void main() {
  test('decoded picture budgets respect the existing memory tiers', () {
    const mib = 1024 * 1024;
    expect(playbackCopyQueueBytes(16 * mib), 16 * mib);
    expect(playbackCopyQueueBytes(32 * mib), 32 * mib);
    expect(playbackCopyQueueBytes(64 * mib), 64 * mib);
    expect(playbackCopyQueueBytes(128 * mib), 160 * mib);
    expect(playbackCopyQueueBytes(512 * mib), 160 * mib);
  });
  test('queue reports accept only bounded numeric VD messages', () {
    for (var samples = 0; samples <= 6; samples++) {
      expect(
        pipelineStageMessage('vd', 'Yingyu copy143 queue samples=$samples'),
        isNotNull,
      );
    }
    for (final text in [
      'Yingyu copy143 queue samples=7',
      'Yingyu copy143 queue samples=-1',
      'Yingyu copy143 queue samples=4 arbitrary-private-text',
    ]) {
      expect(pipelineStageMessage('vd', text), isNull);
    }
    expect(
      pipelineStageMessage('ffmpeg/video', 'Yingyu copy143 queue samples=4'),
      isNull,
    );
  });
}
