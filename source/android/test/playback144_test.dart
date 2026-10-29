import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';
import 'host/playback144/parser143.dart' as old;

void main() {
  test('runtime queue snapshot survives warn-only native logging safely', () {
    const valid =
        'Yingyu queue144 samples=6 frames=4 bytes=24883200 '
        'budget=167772160 rate_milli=3000 cpu=1';
    expect(old.pipelineStageMessage('vd', valid), isNull);
    expect(pipelineStageMessage('vd', valid), contains('当前排队=4'));
    for (final row in [
      valid.replaceFirst('samples=6', 'samples=7'),
      valid.replaceFirst('frames=4', 'frames=65'),
      '$valid private-url',
    ]) {
      expect(pipelineStageMessage('vd', row), isNull);
    }
    expect(pipelineStageMessage('ffmpeg', valid), isNull);
  });
  test('split copy stages preserve numeric and prefix validation', () {
    for (final name in [
      'get_buffer',
      'alloc_frame',
      'plane_copy',
      'release_output',
    ]) {
      final row =
          'Yingyu stage136 name=$name window_us=2000000 calls=100 '
          'ok=99 total_us=100000 max_us=10000 serial=3';
      expect(old.pipelineStageMessage('vd', row), isNull);
      expect(pipelineStageMessage('vd', row), contains('name=$name'));
      expect(pipelineStageMessage('vo/gpu', row), isNull);
      expect(
        pipelineStageMessage('vd', row.replaceFirst('ok=99', 'ok=101')),
        isNull,
      );
    }
  });
  test('HTTP body reports remain bounded and reject arbitrary suffixes', () {
    const row =
        'Yingyu body144 window_us=2000000 calls=20 ok=19 '
        'total_us=1500000 max_us=300000 bytes=1048576 epoch=2';
    expect(old.pipelineStageMessage('ffmpeg/http', row), isNull);
    expect(pipelineStageMessage('ffmpeg/http', row), contains('bytes=1048576'));
    expect(pipelineStageMessage('vd', row), isNull);
    for (final bad in [
      '$row secret',
      row.replaceFirst('epoch=2', 'epoch=4294967296'),
      row.replaceFirst('total_us=1500000', 'total_us=2500000'),
    ]) {
      expect(pipelineStageMessage('ffmpeg', bad), isNull);
    }
  });
}
