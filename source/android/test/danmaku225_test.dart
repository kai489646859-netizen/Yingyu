import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/danmaku_flights.dart';
import 'package:yingyu/playback/danmaku_preferences.dart';
import 'package:yingyu/playback/danmaku_sources.dart';
import 'package:yingyu/playback/danmaku_storage.dart';
import 'package:yingyu/playback/episode_number.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
Uint8List json(Object value) => bytes(jsonEncode(value));

const annual = (
  title: '合成国漫年番',
  season: 6,
  episode: 8,
  absolute: 214,
  year: 0,
  seconds: 120,
  continuous: true,
);

void main() {
  test(
    'season catalogue variants start before an earlier variant returns',
    () async {
      final first = Completer<Uint8List>();
      final started = <String>{};
      final source = DanmakuSources(
        read: (uri) async {
          if (uri.host != 'api.so.360kan.com') return json({});
          final keyword = uri.queryParameters['kw']!;
          started.add(keyword);
          return keyword == '合成剧 第3季' ? first.future : json({});
        },
      );
      addTearDown(source.close);
      final matching = source.match((
        title: '合成剧',
        season: 3,
        episode: 8,
        absolute: 0,
        year: 0,
        seconds: 120,
        continuous: false,
      ));
      try {
        await Future<void>.delayed(Duration.zero);
        expect(started, containsAll(['合成剧 第3季', '合成剧 第三季', '合成剧']));
      } finally {
        first.complete(json({}));
        await matching;
      }
    },
  );

  test(
    'Bilibili queries and verified season details run in parallel',
    () async {
      final first = Completer<Uint8List>();
      final firstSeason = Completer<Uint8List>();
      final started = <String>{};
      final details = <String>{};
      final source = DanmakuSources(
        read: (uri) async {
          if (uri.host != 'api.bilibili.com') return json({});
          if (uri.path.endsWith('/search/type')) {
            final title = uri.queryParameters['keyword']!;
            started.add(title);
            if (title == '合成剧 第3季') return first.future;
            return json({
              'data': {
                'result': [
                  {'title': '合成剧 第三季', 'season_id': 28},
                ],
              },
            });
          }
          final season = uri.queryParameters['season_id']!;
          details.add(season);
          if (season == '27') return firstSeason.future;
          return json({});
        },
      );
      addTearDown(source.close);
      final search = source.search(
        (
          title: '合成剧',
          season: 3,
          episode: 8,
          absolute: 0,
          year: 0,
          seconds: 120,
          continuous: false,
        ),
        '合成剧',
        hidden: {'腾讯视频', '芒果 TV', '爱奇艺'},
      );
      try {
        await Future<void>.delayed(Duration.zero);
        expect(started, containsAll(['合成剧 第3季', '合成剧 第三季']));
        first.complete(
          json({
            'data': {
              'result': [
                {'title': '合成剧 第3季', 'season_id': 27},
              ],
            },
          }),
        );
        await Future<void>.delayed(Duration.zero);
        expect(details, containsAll(['27', '28']));
      } finally {
        if (!first.isCompleted) first.complete(json({}));
        firstSeason.complete(json({}));
        expect(await search, isEmpty);
      }
    },
  );

  test(
    'Tencent verifies the direct episode table and Mango handles its single episode URL',
    () async {
      final source = DanmakuSources(
        readTencentSearch: (uri, body) async => json({
          'ret': 0,
          'data': {
            'normalList': {
              'itemList': [
                {
                  'doc': {'id': 'cover01'},
                  'videoInfo': {
                    'title': '合成国漫年番',
                    'videoType': 3,
                    'episodeSites': [
                      {
                        'enName': 'qq',
                        'totalEpisode': 214,
                        'episodeInfoList': [
                          {
                            'id': 'video08',
                            'title': '8',
                            'duration': 120,
                            'url':
                                'https://v.qq.com/x/cover/cover01/video08.html',
                          },
                          {
                            'id': 'trailer08',
                            'title': '8',
                            'duration': 30,
                            'url':
                                'https://v.qq.com/x/cover/cover01/trailer08.html',
                          },
                        ],
                      },
                    ],
                  },
                },
              ],
            },
          },
        }),
        read: (uri) async => switch ((uri.host, uri.path)) {
          ('dm.video.qq.com', '/barrage/base/video08') => json({
            'segment_index': [
              {'segment_name': 't/v1/90000/120000', 'segment_start': 90000},
            ],
          }),
          ('galaxy.bz.mgtv.com', '/rdbarrage') => json({
            'data': {
              'items': [
                {'time': 2000, 'content': '芒果弹幕'},
              ],
            },
          }),
          _ => json({}),
        },
      );
      addTearDown(source.close);
      expect(
        (await source.match(annual)).single.link,
        'https://v.qq.com/x/page/video08.html',
      );
      final mango = (await source.search(
        annual,
        'https://www.mgtv.com/b/11/22.html',
      )).single;
      expect((await mango.segments.first.load()).single.text, '芒果弹幕');
    },
  );

  test(
    'Bilibili resolves a related season and supplements rolling modes from XML',
    () async {
      final requested = <Uri>[];
      final source = DanmakuSources(
        read: (uri) async {
          requested.add(uri);
          return switch (uri.path) {
            '/x/web-interface/search/type'
                when uri.queryParameters['keyword'] == '合成剧' =>
              json({
                'data': {
                  'result': [
                    {'title': '合成剧', 'season_id': 1},
                  ],
                },
              }),
            '/pgc/view/web/season'
                when uri.queryParameters['season_id'] == '1' =>
              json({
                'result': {
                  'title': '合成剧',
                  'type': 1,
                  'seasons': [
                    {'season_id': 3},
                  ],
                },
              }),
            '/pgc/view/web/season'
                when uri.queryParameters['season_id'] == '3' =>
              json({
                'result': {
                  'title': '合成剧第三季',
                  'type': 1,
                  'episodes': [
                    {'title': '8', 'id': 88, 'cid': 123, 'duration': 120000},
                    {
                      'title': '8',
                      'id': 89,
                      'cid': 124,
                      'duration': 120000,
                      'long_title': '预告',
                    },
                  ],
                },
              }),
            '/x/v2/dm/web/seg.so' => Uint8List.fromList([
              10,
              12,
              16,
              100,
              24,
              1,
              40,
              255,
              255,
              255,
              7,
              58,
              1,
              65,
            ]),
            '/x/v1/dm/list.so' => bytes('<i><d p="2,3,24,16777215">补齐</d></i>'),
            _ => json({}),
          };
        },
      );
      addTearDown(source.close);
      final track = (await source.match((
        title: '合成剧',
        season: 4,
        episode: 8,
        absolute: 0,
        year: 0,
        seconds: 120,
        continuous: false,
      ))).single;
      expect(track.link, endsWith('ep88'));
      expect((await track.segments.single.load()).single.text, 'A');
      expect(requested.where((uri) => uri.path == '/x/v1/dm/list.so'), isEmpty);
      final row = (await track.supplements.single.load()).single;
      expect((row.text, row.mode), ('补齐', 1));
      expect(
        requested.where((uri) => uri.path == '/x/v1/dm/list.so'),
        hasLength(1),
      );
    },
  );

  test(
    'selection cache is scoped and late writes cannot refill a cleared cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yingyu-danmaku225-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final storage = DanmakuStorage(() async => directory);
      final old = storage.generation;
      await storage.write(
        'selection/account-a/item',
        bytes('public episode'),
        old,
      );
      expect(
        utf8.decode((await storage.read('selection/account-a/item'))!),
        'public episode',
      );
      expect(await storage.read('selection/account-b/item'), isNull);
      expect(await storage.clear(), isTrue);
      await storage.write('selection/account-a/item', bytes('stale'), old);
      expect(await storage.read('selection/account-a/item'), isNull);
    },
  );

  test(
    'visible rows change pace in place while late rows queue at the edge',
    () {
      final flights = DanmakuFlights();
      const first = DanmakuComment(.1, '第一条', 1, 0xffffff);
      const second = DanmakuComment(.21, '第二条', 1, 0xffffff);
      void step(
        double time,
        List<DanmakuComment> rows, {
        double rate = 1,
        int lanes = 1,
      }) {
        flights.advance(
          comments: rows,
          time: time,
          viewport: 800,
          lanes: lanes,
          appearance: defaultDanmakuAppearance,
          measure: (_) => 80,
          playbackRate: rate,
        );
      }

      step(0, []);
      step(.2, [first]);
      final inFlight = flights.active.single;
      step(.3, [first, second]);
      final x = inFlight.x(flights.motion, 800);
      step(.3, [first, second], rate: 2);
      expect(inFlight.x(flights.motion, 800), closeTo(x, .001));
      expect(inFlight.travel, 4.5);
      step(.5, [first, second], rate: 2, lanes: 2);
      expect(x - inFlight.x(flights.motion, 800), closeTo(800 * .2 / 9, .001));
      expect(flights.active.last.comment, second);
      expect(flights.active.last.x(flights.motion, 800), 800);
      expect(flights.active.last.travel, 4.5);
      var time = .5;
      for (final rate in [3.0, 2.0, 1.0]) {
        final before = inFlight.x(flights.motion, 800);
        step(time, [first, second], rate: rate, lanes: 2);
        expect(inFlight.x(flights.motion, 800), closeTo(before, .001));
        time += rate / 10;
        step(time, [first, second], rate: rate, lanes: 2);
        expect(
          before - inFlight.x(flights.motion, 800),
          closeTo(800 * rate / 90, .001),
        );
      }
    },
  );

  test(
    'featured keeps the first two repeats and limits distinct rolling bursts',
    () {
      const rows = [
        DanmakuComment(.1, '重复', 1, 0xffffff),
        DanmakuComment(.3, '另一轨', 1, 0xffffff),
        DanmakuComment(.5, '重复', 1, 0xffffff),
        DanmakuComment(.6, '不同内容', 1, 0xffffff),
      ];
      List<DanmakuComment> play(
        List<DanmakuComment> feed, {
        required bool featured,
      }) {
        final flights = DanmakuFlights();
        for (final time in [0.0, .2, .4, .55, .7]) {
          flights.advance(
            comments: feed,
            time: time,
            viewport: 800,
            lanes: 6,
            appearance: defaultDanmakuAppearance.update(featured: featured),
            measure: (_) => 50,
          );
        }
        return flights.active.map((row) => row.comment).toList();
      }

      expect(play(rows, featured: false), rows);
      expect(play(rows, featured: true), rows.take(3));
      expect(play([rows[0], rows[2]], featured: true), [rows[0], rows[2]]);
    },
  );

  test('episode fallback requires an explicit ordinal', () {
    expect(playbackEpisodeNumber(MediaItem({'Name': '合成剧 第8集'})), 8);
    expect(playbackEpisodeNumber(MediaItem({'Name': '合成剧 214'})), 0);
    expect(
      DanmakuSources.compatibleAddresses(
        'https://one.example\nhttps://two.example/api/v2\nhttps://api.dandanplay.net',
      ).map((uri) => uri.host),
      ['one.example', 'two.example'],
    );
    expect(
      DanmakuSources.compatibleAddress('http://127.0.0.1:4100'),
      isNotNull,
    );
    expect(DanmakuSources.compatibleAddress('http://lan.example'), isNull);
  });
}
