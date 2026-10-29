import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';

String row(String layer, int tag) =>
    'Yingyu probe169 layer=$layer win_us=2000000 a=0 b=100 c=20 d=0 '
    'max_us=8000 gap_us=6000000 head_ms=15000 tail_ms=15040 '
    'target_ms=26000 depth=2 flags=0 tag=$tag';

void main() {
  test('three boundaries remain numeric and are explicitly diagnostic', () {
    for (final (layer, prefix, tag) in [
      ('codec', 'ffmpeg/video', 3),
      ('queue', 'vd', 2),
      ('player', 'cplayer', 2000),
    ]) {
      final result = pipelineStageMessage(prefix, row(layer, tag));
      expect(result, contains('卡帧边界核对'));
      expect(result, contains('gap_us=6000000'));
      expect(result, contains('非物理呈现'));
      for (final other in ['vd', 'cplayer', 'ffmpeg/video', 'vo/gpu']) {
        if (other != prefix) {
          expect(pipelineStageMessage(other, row(layer, tag)), isNull);
        }
      }
    }
  });
  test(
    'accept missing frames and long stalls without converting them to zero',
    () {
      final sample = row('player', 3000)
          .replaceFirst('win_us=2000000', 'win_us=120000000')
          .replaceFirst('head_ms=15000', 'head_ms=-1')
          .replaceFirst('tail_ms=15040', 'tail_ms=-1');
      expect(pipelineStageMessage('cplayer', sample), contains('head_ms=-1'));
      expect(
        pipelineStageMessage('cplayer', sample),
        contains('win_us=120000000'),
      );
    },
  );
  test('reject malformed values, foreign prefixes and arbitrary payloads', () {
    final sample = row('player', 2000);
    for (final bad in [
      '$sample url=private',
      sample.replaceFirst('target_ms=26000', 'target_ms=NaN'),
      sample.replaceFirst('head_ms=15000', 'head_ms=-2'),
      sample.replaceFirst('win_us=2000000', 'win_us=1999999'),
      sample.replaceFirst('b=100', 'b=9999999999'),
      sample.replaceFirst('depth=2', 'depth=9999'),
      sample.replaceFirst('flags=0', 'flags=8'),
      sample.replaceFirst('tag=2000', 'tag=1000'),
      sample.replaceFirst('tag=2000', 'tag=3001'),
      'hevc_mediacodec: $sample',
    ]) {
      expect(pipelineStageMessage('cplayer', bad), isNull, reason: bad);
    }
    expect(
      pipelineStageMessage(
        'ffmpeg/video',
        'hevc_mediacodec: ${row('codec', 3)}',
      ),
      contains('layer=codec'),
    );
  });
}
