import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show VideoParams;
import 'host/notice103/notice_projection.dart' as current;
import 'host/notice103/old_notice_projection.dart' as old;

void main() {
  test(
    'full old/current backend notice getters differ only when a positive decoded range arrives after its first snapshot',
    () {
      final before = old.NoticeProjection(), after = current.NoticeProjection();
      expect(before.sourceNotice, '');
      expect(after.sourceNotice, '');
      before.player.state.videoParams = const VideoParams(gamma: 'pq');
      after.player.state.videoParams = const VideoParams(gamma: 'pq');
      expect(before.sourceNotice, '');
      expect(after.sourceNotice, 'SDR · 已做色彩适配');
    },
  );
  test(
    'late actual Dolby matrix still reports compatible SDR, without inventing native Dolby output',
    () {
      final h = current.NoticeProjection();
      h.player.state.videoParams = const VideoParams(
        colormatrix: 'dolbyvision',
      );
      expect(h.sourceNotice, '杜比映射 SDR');
    },
  );
  test(
    'late HLG text requires established HDR and unknown metadata cannot erase known transfer evidence',
    () {
      final h = current.NoticeProjection()..snapshot(hdr: true);
      h.player.state.videoParams = const VideoParams(gamma: 'hlg');
      expect(h.sourceNotice, 'HLG · 高动态范围');
      h.snapshot(hdr: true, decoded: {'video-params/gamma': 'hlg'});
      h.player.state.videoParams = const VideoParams(gamma: 'auto');
      expect(h.sourceNotice, 'HLG · 高动态范围');
    },
  );
  test(
    'not ready or unknown stays silent; confirmed ordinary SDR gets its own notice',
    () {
      final h = current.NoticeProjection()..snapshot(ready: false);
      h.player.state.videoParams = const VideoParams(gamma: 'pq');
      expect(h.sourceNotice, '');
      h.snapshot();
      h.player.state.videoParams = const VideoParams(gamma: 'auto');
      expect(h.sourceNotice, '');
      h.player.state.videoParams = const VideoParams(gamma: 'bt.1886');
      expect(h.sourceNotice, 'SDR · 标准动态范围');
    },
  );
}
