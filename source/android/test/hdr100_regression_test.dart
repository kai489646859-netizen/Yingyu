import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/native_hdr.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/media_notice.dart';

void main() {
  test(
    'actual pinned MKV demuxer format may enter HDR on a compatible screen',
    () {
      expect(
        nativeHdrTransfer(
          requested: true,
          disc: false,
          source: DetectedVideoRange.hdr10,
          container: 'mkv',
          capabilities: const OutputCapabilities(sdk: 34, display: 0, hdr: {2}),
        ),
        'pq',
      );
    },
  );
  test(
    'screen bottom is user zero although native MPV bottom is one hundred',
    () async {
      expect(
        await readMpvSubtitlePosition(
          read: (_) async => '100',
          active: () => true,
        ),
        0,
      );
    },
  );
  test(
    'moving to user 75 percent writes native 25 without changing tracks',
    () async {
      var native = '100';
      final writes = <String>[];
      final result = await writeMpvSubtitlePosition(
        value: 75,
        read: (_) async => native,
        write: (key, value) async {
          writes.add(key);
          native = value;
        },
        active: () => true,
      );
      expect(result, 75);
      expect(double.parse(native), 25);
      expect(writes, ['sub-pos']);
    },
  );
  test(
    'primary playback notice separates current picture output from source audio branding',
    () {
      final text = mediaNotice(
        bluray: false,
        streams: const [],
        decoded: const {
          'video-params/gamma': 'pq',
          'audio-codec-name': 'truehd',
        },
      );
      expect(text, contains('色彩适配'));
      expect(text, contains('SDR'));
      expect(text, isNot(contains('Dolby TrueHD')));
    },
  );
}
