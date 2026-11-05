import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/server_resume.dart';
import 'package:yingyu/playback/danmaku_sources.dart';
import 'package:yingyu/ui/watch_progress.dart';

Uint8List payload(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test('sparse cached Resume uses its own validated percentage', () {
    final item = ServerResumeItem(
      MediaItem(
        displayMetadata({
          'Id': 'episode198',
          'Type': 'Episode',
          'UserData': {
            'PlaybackPositionTicks': 7394400000,
            'PlayedPercentage': 60.45,
          },
        }),
      ),
    );
    final progress = WatchProgressState.resolve(item, null, null);
    expect(progress.known, isTrue);
    expect(progress.fraction, closeTo(.6045, .00001));
    expect(progress.position, const Duration(milliseconds: 739440));
  });

  test(
    'blocked Bilibili search falls back to a season anchor, rejects trailer, loads resume segment',
    () async {
      final client = DanmakuSources(
        read: (uri) async {
          return switch ((uri.host, uri.path)) {
            ('api.bilibili.com', '/x/web-interface/search/type') =>
              throw const FormatException('HTTP 412'),
            ('api.so.360kan.com', '/index') => payload({
              'data': {
                'longData': {
                  'rows': [
                    {
                      'titleTxt': '合成国漫',
                      'cat_name': '动漫',
                      'en_id': 'series',
                      'playlinks': {
                        'bilibili1':
                            'https://www.bilibili.com/bangumi/play/ep1960000',
                      },
                    },
                  ],
                },
              },
            }),
            ('api.web.360kan.com', '/v1/detail') => payload({
              'data': {'allepidetail': null},
            }),
            ('api.bilibili.com', '/pgc/view/web/season')
                when uri.queryParameters['ep_id'] == '1960000' =>
              payload({
                'code': 0,
                'result': {
                  'title': '合成国漫',
                  'episodes': [
                    {
                      'title': '196',
                      'id': 1960000,
                      'cid': 196,
                      'duration': 1224000,
                    },
                    {
                      'title': '198',
                      'id': 1980001,
                      'cid': 1981,
                      'duration': 49000,
                      'badge': '预告',
                    },
                    {
                      'title': '198',
                      'id': 1980002,
                      'cid': 1982,
                      'duration': 1224000,
                    },
                  ],
                },
              }),
            ('api.bilibili.com', '/x/v2/dm/web/seg.so')
                when uri.queryParameters['oid'] == '1982' &&
                    uri.queryParameters['segment_index'] == '3' =>
              Uint8List(0),
            ('comment.bilibili.com', '/1982.xml') => Uint8List.fromList(
              utf8.encode('<i><d p="740,1,24,16777215">正片弹幕</d></i>'),
            ),
            _ => throw StateError('unexpected test request'),
          };
        },
      );
      addTearDown(client.close);
      final item = MediaItem({
        'Type': 'Episode',
        'SeriesName': '合成国漫',
        'ParentIndexNumber': 1,
        'IndexNumber': 198,
      });
      final tracks = await client.match(
        danmakuIdentity(item, const Duration(milliseconds: 1223296))!,
      );
      final track = tracks.single;
      expect(track.source, '哔哩哔哩');
      final segment = track.segments.singleWhere(
        (row) => row.start <= 739 && row.end > 739,
      );
      expect((await segment.load()).single.text, '正片弹幕');
    },
  );
}
