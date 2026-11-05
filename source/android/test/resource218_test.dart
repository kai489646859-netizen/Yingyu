import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/video_labels.dart';
import 'package:yingyu/core/version_groups.dart';

void main() {
  test(
    'structured profile aliases and ranges agree across version entries',
    () {
      for (final key in ['DoviProfile', 'DvProfile', 'DolbyVisionProfile']) {
        final video = {'Type': 'Video', key: 8};
        expect(videoRangeLabel(video), '杜比视界 P8');
        expect(
          sourceDescription({
            'MediaStreams': [video],
          }),
          contains('杜比视界 P8'),
        );
      }
      expect(
        videoRangeLabel({'VideoRangeType': '', 'VideoRange': 'HDR10'}),
        'HDR10',
      );
      expect(
        videoRangeLabel({'VideoRangeType': 'unknown', 'VideoRange': 'HLG'}),
        'HLG',
      );
      expect(videoRangeLabel({'VideoRangeType': 'HDR10Plus'}), 'HDR10+');
      expect(videoRangeLabel({'VideoRange': 'DOVIWithHDR10'}), '杜比视界');
      expect(videoRangeLabel({'ExtendedVideoType': 'DolbyVision'}), '杜比视界');
      expect(videoRangeLabel({'DvProfile': 99, 'Title': 'Dolby 4K'}), '');
      expect(mediaSourceFacts({'Name': 'Dolby 4K', 'Path': 'HDR10.mkv'}), '');
      expect(videoRangeLabel({}), '');
    },
  );

  test('cached technical metadata keeps labels without playback addresses', () {
    final cached = displayMetadata({
      'MediaSources': [
        {
          'Id': 'file',
          'Path': 'private-path',
          'DirectStreamUrl': 'private-url',
          'MediaStreams': [
            {
              'Type': 'Video',
              'DoviProfile': 8,
              'ExtendedVideoType': 'DolbyVision',
              'Width': 3840,
              'Height': 2160,
              'Path': 'private-stream',
            },
          ],
        },
      ],
    });
    final facts = mediaSourceFacts(objects(cached['MediaSources']).single);
    expect(facts, contains('杜比视界 P8'));
    expect(facts, contains('4K'));
    expect(cached.toString(), isNot(contains('private-')));
  });

  test(
    'portrait dimensions and missing dimensions do not invent resolution',
    () {
      for (final size in [
        [3840, 1600, '4K'],
        [1440, 2560, '1440p'],
        [1080, 1920, '1080p'],
      ]) {
        expect(
          videoResolutionLabel({'Width': size[0], 'Height': size[1]}),
          size[2],
        );
      }
      expect(videoResolutionLabel({'Width': 3840}), '');
      expect(videoResolutionLabel({'Width': -1, 'Height': 2160}), '');
    },
  );

  test('one source never borrows technical labels from another file', () {
    final item = MediaItem({
      'Name': '同片',
      'MediaStreams': [
        {'Type': 'Video', 'Width': 3840, 'Height': 2160, 'DvProfile': 8},
      ],
      'MediaSources': [
        {
          'Id': 'first',
          'Name': '普通版本',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Width': 1920,
              'Height': 1080,
              'VideoRange': 'SDR',
            },
          ],
        },
        {'Id': 'second', 'Name': '另一文件'},
      ],
    });
    expect(versionDescription(item), contains('1080p'));
    expect(versionDescription(item), isNot(contains('杜比视界')));
    expect(versionDescription(item), isNot(contains('4K')));
  });
}
