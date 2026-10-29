import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

const row =
    'Yingyu timing162 video=562.240000 audio=564.017279 timer=-0.567000 delay=2.000000 ao=0.100000 vspeed=3.000000 aspeed=3.000000 correction=0.010000 duration_ns=13333333 queued=2 span_us=12';
void main() {
  test('bounded timing observer is numeric, labelled and source scoped', () {
    final result = pipelineStageMessage('cplayer', row);
    expect(result, contains('倍速排期核对'));
    expect(result, contains('timer=-0.567000'));
    expect(result, contains('非原子音画读数'));
    for (final prefix in ['vd', 'ffmpeg/video', 'vo/gpu']) {
      expect(pipelineStageMessage(prefix, row), isNull);
    }
  });
  test('malformed, unsupported or unbounded timing values never escape', () {
    for (final bad in [
      '$row private-token',
      row.replaceFirst('562.240000', 'NaN'),
      row.replaceFirst('562.240000', '-562.240000'),
      row.replaceFirst('vspeed=3.000000', 'vspeed=1.000000'),
      row.replaceFirst('queued=2', 'queued=99'),
      row.replaceFirst('span_us=12', 'span_us=9000000'),
    ]) {
      expect(pipelineStageMessage('cplayer', bad), isNull);
    }
  });
}
