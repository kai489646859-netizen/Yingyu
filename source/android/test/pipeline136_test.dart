import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

void main() {
  const row =
      'Yingyu stage136 name=copy_api window_us=2000000 calls=100 '
      'ok=100 total_us=600000 max_us=9000 serial=2';
  test('codec stage retains measured counts and explicit timing limits', () {
    final result = pipelineStageMessage('ffmpeg/video', row)!;
    expect(pipelineStageMessage('vd', row), result);
    expect(result, contains('calls=100 ok=100 total_us=600000 max_us=9000'));
    expect(result, contains('非解码/GPU执行延迟'));
    expect(
      pipelineStageMessage('ffmpeg/video', 'hevc_mediacodec: $row'),
      result,
    );
  });
  test('late output release remains visible and is not a smoothness claim', () {
    final value = row.replaceFirst('copy_api', 'copy_drop');
    expect(pipelineStageMessage('vd', value), contains('复制前过时输出释放次数'));
    expect(pipelineStageMessage('vd', value), contains('不能作为流畅度结论'));
    expect(pipelineStageMessage('vo/gpu', value), isNull);
  });
  test('native upload, swap and fence prefixes are whitelisted separately', () {
    for (final name in ['upload_api', 'swap_api', 'fence_api']) {
      final value = row.replaceFirst('copy_api', name);
      expect(pipelineStageMessage('vo/gpu/opengl', value), isNotNull);
      expect(pipelineStageMessage('vo/gpu', value), isNotNull);
      expect(pipelineStageMessage('ffmpeg/video', value), isNull);
    }
    expect(pipelineStageMessage('vo/gpu', row), isNull);
  });
  test(
    'malformed and arbitrary native strings cannot enter numeric records',
    () {
      for (final value in [
        '$row\nsecret',
        row.replaceFirst('ok=100', 'ok=101'),
        row.replaceFirst('calls=100', 'calls=0'),
        row.replaceFirst('total_us=600000', 'total_us=2000001'),
        row.replaceFirst('max_us=9000', 'max_us=600001'),
        row.replaceFirst('serial=2', 'serial=4294967296'),
        row.replaceFirst('window_us=2000000', 'window_us=1999999'),
        row.replaceFirst('copy_api', 'unknown'),
        row.replaceFirst('serial=2', 'serial=https://private.invalid'),
      ]) {
        expect(pipelineStageMessage('ffmpeg/video', value), isNull);
      }
      expect(pipelineStageMessage('arbitrary', row), isNull);
    },
  );
}
