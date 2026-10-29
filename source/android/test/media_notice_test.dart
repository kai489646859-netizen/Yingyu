import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/media_notice.dart';
import 'package:yingyu/playback/diagnostics.dart';
import 'package:yingyu/playback/disc_transport.dart';

void main() {
  test(
    'Emby structured HDR/Dolby fields survive unavailable native profile',
    () {
      expect(
        mediaNotice(
          bluray: false,
          streams: [
            {
              'Type': 'Video',
              'ExtendedVideoType': 'DolbyVision',
              'ExtendedVideoSubType': 'DoviProfile76',
              'VideoRange': 'HDR',
            },
          ],
          decoded: {'dolby-vision-profile': '未提供', 'video-params/gamma': 'pq'},
        ),
        '杜比映射 SDR',
      );
      expect(
        mediaNotice(
          bluray: false,
          streams: [
            {'Type': 'Video', 'ExtendedVideoType': 'HyperLogGamma'},
          ],
        ),
        'SDR · 已做色彩适配',
      );
      expect(
        mediaNotice(
          bluray: false,
          streams: [
            {'Type': 'Video', 'ExtendedVideoType': 'Hdr10Plus'},
          ],
        ),
        'SDR · 已做色彩适配',
      );
      expect(
        mediaNotice(
          bluray: false,
          streams: [
            {
              'Type': 'Video',
              'ExtendedVideoType': 'unknown',
              'ExtendedVideoSubType': 'DoviProfile999',
            },
          ],
        ),
        '',
      );
    },
  );
  test(
    'source notice combines actual Blu-ray and Dolby metadata without claiming Atmos or FEL',
    () {
      final notice = mediaNotice(
        bluray: true,
        streams: [],
        decoded: {'dolby-vision-profile': '7', 'audio-codec-name': 'truehd'},
      );
      expect(notice, '杜比映射 SDR · 蓝光原盘');
      expect(notice, isNot(contains('Atmos')));
      expect(notice, isNot(contains('FEL')));
    },
  );
  test(
    'ordinary source and HDR/HLG notices are based on stream fields, not filenames',
    () {
      expect(
        mediaNotice(
          bluray: false,
          streams: [
            {'Type': 'Video', 'Title': 'BluRay.DolbyVision.HDR'},
          ],
        ),
        '',
      );
      expect(
        mediaNotice(
          bluray: false,
          streams: [
            {'Type': 'Video', 'ColorTransfer': 'smpte2084'},
          ],
          decoded: {'video-params/gamma': '未提供'},
        ),
        'SDR · 已做色彩适配',
      );
      expect(
        mediaNotice(
          bluray: false,
          streams: [],
          decoded: {'video-params/gamma': 'hlg'},
        ),
        'SDR · 已做色彩适配',
      );
      expect(
        mediaNotice(
          bluray: false,
          streams: [],
          decoded: {'video-params/colormatrix': 'dolbyvision'},
        ),
        '杜比映射 SDR',
      );
    },
  );
  test('invalid profiles never become invented Dolby badges', () {
    expect(
      mediaNotice(
        bluray: false,
        streams: [],
        decoded: {'dolby-vision-profile': '99'},
      ),
      '',
    );
  });
  test(
    'only recoverable decoder initialization diagnostics are deferred; terminal failures remain errors',
    () {
      expect(decoderMayFallback('Could not open codec.'), true);
      for (final error in [
        'Failed to initialize a decoder.',
        'Failed to open media.',
        'HTTP error 403 Forbidden',
        'Audio device failed',
      ]) {
        expect(decoderMayFallback(error), false);
      }
    },
  );
  test('one malformed bonus playlist does not discard a valid main title', () {
    var rejected = 0;
    final titles = readableDiscTitles([
      {
        'playlist': 1,
        'duration': 90000,
        'clips': [
          {'id': 'invalid', 'in': 0, 'out': 90000},
        ],
      },
      {
        'playlist': 2,
        'main': true,
        'duration': 180000,
        'clips': [
          {'id': '00042', 'in': 45000, 'out': 225000},
        ],
      },
      {
        'playlist': 3,
        'duration': 90000,
        'clips': [
          {'id': '00011', 'in': 0, 'out': 90000},
        ],
      },
    ], onRejected: (n) => rejected = n);
    expect(rejected, 1);
    expect(titles.map((t) => t.playlist), [2, 3]);
    expect(
      titles.first.edl('http://127.0.0.1/fixture'),
      contains('00042.m2ts,0.500000,2.000000'),
    );
    expect(
      () => readableDiscTitles([
        {'playlist': 4},
      ]),
      throwsException,
    );
  });
}
