import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/info.dart';
import 'package:yingyu/playback/media_notice.dart';

void main() {
  const serverDolby = <Json>[
    {'Type': 'Video', 'DoviProfile': 7, 'ExtendedVideoType': 'DolbyVision'},
  ];
  PlaybackRoute route({
    List<Json> streams = serverDolby,
    DiscKind kind = DiscKind.none,
  }) => PlaybackRoute(
    url: 'https://synthetic.invalid/original',
    sourceId: 'source',
    sessionId: 'session',
    headers: const {},
    streams: streams,
    discKind: kind,
  );
  String resource({
    List<Json> streams = serverDolby,
    Map<String, String> decoded = const {},
    String disc = '',
    DiscKind kind = DiscKind.none,
    bool allowServer = true,
  }) => playbackResourceType(
    confirmedDisc: disc,
    route: route(streams: streams, kind: kind),
    metadata: {
      'MediaSources': [
        {'Id': 'source', 'Container': 'mkv'},
      ],
    },
    decoded: decoded,
    allowServerFormat: allowServer,
  );

  for (final profile in [5, 8]) {
    test(
      'resource retains its container and prefers actual Dolby Profile $profile',
      () {
        expect(
          resource(
            decoded: {'current-tracks/video/dolby-vision-profile': '$profile'},
          ),
          'MKV · 杜比视界 Profile $profile',
        );
      },
    );
  }
  test('actual Dolby matrix never borrows a conflicting server profile', () {
    expect(
      resource(decoded: {'video-params/colormatrix': 'dolbyvision'}),
      'MKV · 杜比视界',
    );
  });
  test('unavailable actual profile retains unambiguous server evidence', () {
    expect(
      resource(decoded: {'current-tracks/video/dolby-vision-profile': '未提供'}),
      'MKV · 杜比视界 Profile 7',
    );
  });
  test('confirmed disc type is preserved when actual Dolby is appended', () {
    expect(
      resource(
        disc: '蓝光原盘',
        decoded: {'current-tracks/video/dolby-vision-profile': '8'},
      ),
      '蓝光原盘 · 杜比视界 Profile 8',
    );
    expect(
      resource(
        kind: DiscKind.iso,
        decoded: {'video-params/colormatrix': 'dolbyvision'},
      ),
      'ISO · 杜比视界',
    );
    expect(
      resource(
        kind: DiscKind.blurayFolder,
        decoded: {'video-params/colormatrix': 'dolbyvision'},
      ),
      'BDMV · 杜比视界',
    );
  });
  test('current HDR and HLG win over conflicting general server labels', () {
    expect(
      resource(
        streams: [
          {'Type': 'Video', 'ExtendedVideoType': 'HyperLogGamma'},
        ],
        decoded: {'video-params/gamma': 'pq'},
      ),
      'MKV · HDR',
    );
    expect(
      resource(
        streams: [
          {'Type': 'Video', 'ExtendedVideoType': 'Hdr10'},
        ],
        decoded: {'video-params/gamma': 'hlg'},
      ),
      'MKV · HLG',
    );
  });
  test('a PQ or HLG base does not refute structured Dolby evidence', () {
    for (final gamma in ['pq', 'hlg']) {
      expect(
        resource(decoded: {'video-params/gamma': gamma}),
        'MKV · 杜比视界 Profile 7',
      );
    }
  });
  test('ambiguous server video tracks cannot label the current track', () {
    expect(
      resource(
        streams: [
          ...serverDolby,
          {'Type': 'Video', 'Codec': 'h264'},
        ],
      ),
      'MKV',
    );
    expect(
      resource(
        streams: [
          ...serverDolby,
          {'Type': 'Video'},
        ],
        decoded: {'current-tracks/video/dolby-vision-profile': '5'},
      ),
      'MKV · 杜比视界 Profile 5',
    );
  });
  test('missing guarded sample suppresses server format fallback', () {
    expect(resource(allowServer: false), 'MKV');
  });
  test(
    'actual container identifiers survive STRM and stale server wrappers',
    () {
      for (final entry in {
        'mpeg': 'MPEG-PS',
        'mp4': 'MP4',
        'mov': 'MP4 / MOV',
        'hls,applehttp': 'HLS',
        'asf': 'ASF',
        'flv': 'FLV',
        'ogg': 'OGG',
        'nut': 'NUT',
      }.entries) {
        expect(
          playbackResourceType(
            confirmedDisc: '',
            route: route(streams: []),
            metadata: {
              'MediaSources': [
                {'Id': 'source', 'Container': 'strm'},
              ],
            },
            format: entry.key,
          ),
          entry.value,
        );
      }
      expect(
        playbackResourceType(
          confirmedDisc: '',
          route: route(streams: []),
          metadata: {
            'MediaSources': [
              {'Id': 'source', 'Container': 'mkv'},
            ],
          },
          format: 'mpegts',
        ),
        'MPEG-TS',
      );
    },
  );
  test(
    'unknown container keeps current color evidence without inferring Dolby',
    () {
      for (final format in [
        null,
        '',
        'edl',
        'lavf',
        'strm',
        'unknown',
        'https://private.invalid/movie?token=secret',
        '../private.mkv',
        'private.mkv',
        'HDR DolbyVision',
        'a' * 33,
      ]) {
        expect(
          playbackResourceType(
            confirmedDisc: '',
            route: route(streams: []),
            metadata: {'Name': 'Dolby HDR movie.iso'},
            format: format,
            decoded: {'video-params/gamma': 'pq'},
          ),
          '封装格式未识别 · HDR',
        );
      }
    },
  );
  test('outer disc identity survives the internal stream container', () {
    expect(
      playbackResourceType(
        confirmedDisc: '',
        route: route(streams: []),
        metadata: {
          'MediaSources': [
            {'Id': 'source', 'Container': 'iso'},
          ],
        },
        format: 'mpegts',
      ),
      'ISO',
    );
  });
  test('titles and invalid profile numbers do not create a Dolby format', () {
    for (final profile in [0, -1, 99, 5.5]) {
      expect(
        resource(
          streams: [
            {
              'Type': 'Video',
              'DoviProfile': profile,
              'Title': 'DolbyVision HDR',
            },
          ],
          decoded: {'current-tracks/video/dolby-vision-profile': '$profile'},
        ),
        'MKV',
      );
    }
    expect(
      resource(streams: [], decoded: {'video-params/gamma': 'pq'}),
      'MKV · HDR',
    );
  });
  test(
    'opening notice and information format share actual profile precedence',
    () {
      expect(
        mediaNotice(
          bluray: false,
          streams: serverDolby,
          decoded: {'dolby-vision-profile': '8'},
        ),
        '杜比映射 SDR',
      );
      expect(
        sourceVideoFormat(
          streams: serverDolby,
          decoded: {
            'current-tracks/video/dolby-vision-profile': '5',
            'dolby-vision-profile': '8',
          },
        ),
        '杜比视界 Profile 5',
      );
    },
  );
}
