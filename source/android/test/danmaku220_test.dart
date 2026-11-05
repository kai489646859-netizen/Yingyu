import 'dart:convert';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/danmaku_sources.dart';

DanmakuIdentity episode({
  int number = 1,
  int absolute = 0,
  bool continuous = false,
}) => danmakuIdentity(
  MediaItem({
    'Id': 'private-episode',
    'Type': 'Episode',
    'SeriesName': '合成国漫',
    'ParentIndexNumber': 2,
    'IndexNumber': number,
    'AbsoluteEpisodeNumber': absolute,
    'Path': '/private/media/file.mkv',
  }),
  const Duration(seconds: 118),
  continuous: continuous,
)!;

Uint8List json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test(
    'late same-season catalogue evidence unlocks exact annual episode and merges sources',
    () async {
      final requested = <Uri>[];
      final client = DanmakuSources(
        read: (uri) async {
          requested.add(uri);
          return switch ((uri.host, uri.path)) {
            ('api.bilibili.com', '/x/web-interface/search/type') => json({}),
            ('api.so.360kan.com', '/index') => json({
              'data': {
                'longData': {
                  'rows': [
                    {'titleTxt': '合成国漫年番', 'cat_name': '动漫', 'en_id': 'series'},
                  ],
                },
              },
            }),
            ('api.web.360kan.com', '/v1/detail') => json({
              'data': {
                'title': '合成国漫年番',
                'allupinfo': {'qq': 217, 'qiyi': 217, 'bilibili1': 217},
                'allepidetail': {
                  'qq': [
                    {
                      'playlink_num': 1,
                      'url': 'https://v.qq.com/x/cover/test/ABCDEF123.html',
                    },
                  ],
                  'qiyi': [
                    {
                      'playlink_num': 1,
                      'url': 'https://www.iqiyi.com/v_12345678.html',
                    },
                  ],
                  'bilibili1': [
                    {
                      'playlink_num': 1,
                      'url': 'https://www.bilibili.com/bangumi/play/ep321',
                    },
                  ],
                },
              },
            }),
            ('dm.video.qq.com', '/barrage/base/ABCDEF123') => json({
              'segment_index': {
                'one': {
                  'segment_name': 't/v1/90000/120000',
                  'segment_start': 90000,
                },
              },
            }),
            (
              'dm.video.qq.com',
              '/barrage/segment/ABCDEF123/t/v1/90000/120000',
            ) =>
              json({
                'barrage_list': [
                  {'time_offset': 99900, 'content': '腾讯弹幕'},
                  {'time_offset': 100, 'content': '越界弹幕'},
                ],
              }),
            ('pcw-api.iqiyi.com', '/video/video/baseinfo/12345678') => json({
              'data': {'durationSec': 118, 'displayBarrage': true},
            }),
            ('api.bilibili.com', '/pgc/view/web/season') => json({
              'result': {
                'episodes': [
                  {'id': 321, 'cid': 456, 'duration': 118000},
                ],
              },
            }),
            ('api.bilibili.com', '/x/v2/dm/web/seg.so') => Uint8List(0),
            ('comment.bilibili.com', '/456.xml') => Uint8List.fromList(
              utf8.encode('<i><d p="99,1,24,16777215">哔哩哔哩弹幕</d></i>'),
            ),
            ('cmts.iqiyi.com', _) => brotliEncode(
              Uint8List.fromList(
                utf8.encode(
                  '<root><row><showTime>99</showTime><color>#ffffff</color><content>爱奇艺弹幕</content></row></root>',
                ),
              ),
            ),
            _ => throw StateError('unexpected test request'),
          };
        },
      );
      addTearDown(client.close);
      expect(await client.match(episode()), isEmpty);
      expect(requested.where((u) => u.path == '/v1/detail'), isEmpty);
      requested.clear();
      final published = <String>[];
      final matches = await client.match(
        episode(continuous: true),
        onTrack: (track) => published.add(track.source),
      );
      expect(
        matches.map((t) => t.source),
        unorderedEquals(['哔哩哔哩', '腾讯视频', '爱奇艺']),
      );
      expect(published, unorderedEquals(['哔哩哔哩', '腾讯视频', '爱奇艺']));
      final comments = await Future.wait(
        matches.map(
          (track) => track.segments
              .firstWhere((s) => s.start <= 99 && s.end > 99)
              .load(),
        ),
      );
      expect(
        comments.expand((v) => v).map((v) => v.text),
        unorderedEquals(['哔哩哔哩弹幕', '腾讯弹幕', '爱奇艺弹幕']),
      );
      expect(
        requested.every(
          (uri) => uri.scheme == 'https' && !uri.toString().contains('private'),
        ),
        isTrue,
      );
      expect(
        requested
            .where((uri) => uri.host == 'api.web.360kan.com')
            .every(
              (uri) =>
                  uri.queryParameters['start'] == '1' &&
                  uri.queryParameters['end'] == '1',
            ),
        isTrue,
      );
    },
  );

  test(
    'incomplete metadata, redirects in configuration and duration mismatches are rejected',
    () {
      final item = MediaItem({
        'Type': 'Episode',
        'SeriesName': '合成国漫',
        'ParentIndexNumber': 2,
        'IndexNumber': 0,
      });
      expect(danmakuIdentity(item, const Duration(seconds: 100)), isNull);
      expect(DanmakuSources.compatibleAddress('http://example.org'), isNull);
      expect(
        DanmakuSources.compatibleAddress('https://user@example.org'),
        isNull,
      );
      expect(
        DanmakuSources.compatibleAddress('https://example.org/api/v2')!.path,
        '/api/v2/',
      );
      expect(danmakuDurationMatches(118, 0), isFalse);
      expect(danmakuDurationMatches(118, 180), isFalse);
    },
  );
}
