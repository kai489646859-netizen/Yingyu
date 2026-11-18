import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brotli_fast/brotli_fast.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../core/models.dart';
import 'danmaku_storage.dart';
import 'episode_number.dart';

typedef DanmakuIdentity = ({
  String title,
  int season,
  int episode,
  int absolute,
  int year,
  int seconds,
  bool continuous,
});

DanmakuIdentity? danmakuIdentity(
  MediaItem item,
  Duration duration, {
  bool continuous = false,
}) {
  final movie = item.type == 'Movie';
  if (!movie && item.type != 'Episode') return null;
  final title = (movie ? item.title : item.data['SeriesName']?.toString() ?? '')
      .trim();
  final season = movie ? 0 : integer(item.data['ParentIndexNumber']);
  final episode = movie ? 0 : playbackEpisodeNumber(item);
  final seconds =
      (duration > Duration.zero ? duration : item.duration).inSeconds;
  if (title.isEmpty ||
      title == '未命名' ||
      title.length > 160 ||
      RegExp(r'[/\\\x00-\x1f]').hasMatch(title) ||
      (!movie && (season < 1 || episode < 1)) ||
      seconds < 1 ||
      seconds > 86400) {
    return null;
  }
  return (
    title: title,
    season: season,
    episode: episode,
    absolute: integer(item.data['AbsoluteEpisodeNumber']),
    year: movie ? integer(item.year) : 0,
    seconds: seconds,
    continuous: continuous,
  );
}

String _name(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[\s·：:！!《》()（）._-]'), '');

bool danmakuDurationMatches(int seconds, num remote) =>
    remote.isFinite && remote > 0 && (seconds - remote).abs() <= 45;

class DanmakuComment {
  const DanmakuComment(this.time, this.text, this.mode, this.color);
  final double time;
  final String text;
  final int mode, color;
}

typedef DanmakuSegment = ({
  double start,
  double end,
  Future<List<DanmakuComment>> Function() load,
});

class DanmakuTrack {
  const DanmakuTrack(
    this.source,
    this.segments, {
    this.link,
    this.label,
    this.supplements = const [],
  });
  final String source;
  final String? link, label;
  final List<DanmakuSegment> segments, supplements;
  Iterable<DanmakuSegment> get allSegments sync* {
    yield* segments;
    yield* supplements;
  }
}

const _publicDanmakuSites = {
  'bilibili1': '哔哩哔哩',
  'qq': '腾讯视频',
  'qiyi': '爱奇艺',
  'imgo': '芒果 TV',
};

/// A playback-owned client with no Emby headers, cookies, redirects or URLs.
class DanmakuSources {
  DanmakuSources({
    this._read,
    this.onBilibiliSearchStatus,
    this.storage,
    this.readTencentSearch,
  }) : cacheGeneration = storage?.generation ?? 0;
  final DanmakuStorage? storage;
  final int cacheGeneration;
  final Future<Uint8List> Function(Uri, Map<String, Object>)? readTencentSearch;
  final void Function(int)? onBilibiliSearchStatus;
  final Future<Uint8List> Function(Uri)? _read;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  void close() => _client.close(force: true);

  Future<Uint8List> _bytes(Uri uri, {Map<String, Object>? body}) async {
    if (body != null && readTencentSearch != null) {
      return readTencentSearch!(uri, body);
    }
    if (_read != null) {
      if (body != null) throw const FormatException('缺少腾讯搜索夹具');
      return _read(uri);
    }
    final request = await _client
        .openUrl(body == null ? 'GET' : 'POST', uri)
        .timeout(const Duration(seconds: 6));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
    if (uri.host == 'api.bilibili.com') {
      request.headers.set(
        HttpHeaders.refererHeader,
        'https://www.bilibili.com/',
      );
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.headers.set('Origin', 'https://v.qq.com');
      request.headers.set(HttpHeaders.refererHeader, 'https://v.qq.com/');
      request.write(jsonEncode(body));
    }
    final deadline = Stopwatch()..start();
    try {
      return await (() async {
        final response = await request.close();
        if (response.statusCode != 200) {
          if (uri.path == '/x/web-interface/search/type') {
            onBilibiliSearchStatus?.call(response.statusCode);
          }
          throw const FormatException('弹幕源响应异常');
        }
        final output = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (output.length + chunk.length > 4 * 1024 * 1024 ||
              deadline.elapsed > const Duration(seconds: 8)) {
            throw const FormatException('弹幕响应超过限制');
          }
          output.add(chunk);
        }
        return output.takeBytes();
      })().timeout(const Duration(seconds: 8));
    } finally {
      request.abort();
    }
  }

  Future<Json> _json(
    String host,
    String path, [
    Map<String, String>? query,
  ]) async => object(
    jsonDecode(utf8.decode(await _bytes(Uri.https(host, path, query)))),
  );

  Future<T?> _available<T>(Future<T?> Function() action) async {
    try {
      return await action();
    } catch (_) {
      return null;
    }
  }

  Future<DanmakuTrack?> _firstMatch(List<Future<DanmakuTrack?>> routes) {
    final result = Completer<DanmakuTrack?>();
    for (final route in routes) {
      unawaited(
        route.then((track) {
          if (track != null && !result.isCompleted) result.complete(track);
        }),
      );
    }
    unawaited(
      Future.wait(routes).then((_) {
        if (!result.isCompleted) result.complete(null);
      }),
    );
    return result.future;
  }

  Future<List<DanmakuTrack>> match(
    DanmakuIdentity id, {
    Uri? compatible,
    List<Uri> alternatives = const [],
    void Function(DanmakuTrack)? onTrack,
    Set<String> hidden = const {},
  }) async {
    final baseTitle = id.title.replaceFirst(RegExp(r'\s*年番$'), '');
    final continuous =
        id.episode > 0 &&
        baseTitle.isNotEmpty &&
        (id.continuous ||
            id.episode >= 75 ||
            id.absolute > id.episode ||
            baseTitle != id.title);
    final titles = <String>{
      if (id.season > 1) ...[
        '${id.title} 第${id.season}季',
        '${id.title} 第${_chinese(id.season)}季',
      ],
      if (id.season <= 1) id.title,
      if (continuous) ...[baseTitle, '$baseTitle 年番'],
    };
    final catalog = <String, Future<List<Json>>>{};
    Future<List<Json>> search(String title) =>
        catalog.putIfAbsent(title, () async {
          final json = await _available(
            () => _json('api.so.360kan.com', '/index', {
              'force_v': '1',
              'from': '',
              'pageno': '1',
              'v_ap': '1',
              'tab': 'all',
              'kw': title,
            }),
          );
          return objects(
            object(object(json?['data'])['longData'])['rows'],
          ).take(40).toList();
        });
    Future<DanmakuTrack?> publish(Future<DanmakuTrack?> pending) async {
      final track = await pending;
      if (track != null) onTrack?.call(track);
      return track;
    }

    return (await Future.wait([
      if (!hidden.contains('哔哩哔哩'))
        publish(
          _firstMatch([
            _available(() => _bilibiliSearch(id, titles)),
            _available(() => _catalogMatch(id, titles, search, 'bilibili1')),
            if (id.season > 1) _available(() => _bilibiliFamily(id, search)),
          ]),
        ),
      if (!hidden.contains('腾讯视频'))
        publish(
          _firstMatch([
            _available(() => _catalogMatch(id, titles, search, 'qq')),
            if (id.episode > 0) _available(() => _tencentSearch(id, titles)),
          ]),
        ),
      if (!hidden.contains('爱奇艺'))
        publish(_available(() => _catalogMatch(id, titles, search, 'qiyi'))),
      if (!hidden.contains('芒果 TV'))
        publish(_available(() => _catalogMatch(id, titles, search, 'imgo'))),
      if (compatible != null && !hidden.contains('兼容弹幕服务'))
        publish(_available(() => _compatible(id, compatible))),
      if (!hidden.contains('兼容弹幕服务'))
        for (final uri in alternatives)
          publish(_available(() => _compatible(id, uri))),
    ])).nonNulls.toList();
  }

  Future<List<DanmakuTrack>> search(
    DanmakuIdentity id,
    String query, {
    Uri? compatible,
    List<Uri> alternatives = const [],
    Set<String> hidden = const {},
  }) async {
    final title = query.trim();
    if (title.isEmpty || title.length > 320) return [];
    final url = Uri.tryParse(title);
    if (url != null && url.hasScheme) {
      for (final site in _publicDanmakuSites.keys) {
        if (hidden.contains(_publicDanmakuSites[site])) continue;
        final video = _publicVideo(title, site);
        if (video == null) continue;
        final track = await _available(
          () => switch (site) {
            'qq' => _tencent(id, video),
            'qiyi' => _iqiyi(id, video),
            'imgo' => _mango(id, video),
            _ => _bilibiliSeason(id, {'ep_id': video}, explicit: true),
          },
        );
        return [?track];
      }
      return [];
    }
    if (RegExp(r'[/\\\x00-\x1f]').hasMatch(title)) return [];
    final queryIdentity = (
      title: title,
      season: id.season,
      episode: id.episode,
      absolute: id.absolute,
      year: id.year,
      seconds: id.seconds,
      continuous: id.continuous,
    );
    final [matched, manual] = await Future.wait([
      match(
        queryIdentity,
        compatible: compatible,
        alternatives: alternatives,
        hidden: hidden,
      ),
      if (hidden.contains('哔哩哔哩'))
        Future.value(<DanmakuTrack>[])
      else
        _bilibiliCandidates(queryIdentity, {title, '$title 第${id.season}季'}),
    ]);
    final links = <String>{};
    return [
      ...matched,
      ...manual,
    ].where((track) => track.link == null || links.add(track.link!)).toList();
  }

  static Future<DanmakuTrack?> localXml(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 4 * 1024 * 1024) return null;
    final rows = await compute(_biliXml, bytes);
    if (rows.isEmpty) return null;
    return DanmakuTrack('本地 XML', [
      (start: 0, end: 86401, load: () async => rows),
    ]);
  }

  static String _chinese(int value) =>
      value < 10 && value > 0 ? '零一二三四五六七八九'[value] : '$value';

  // The bare title is safe for season one. Later seasons need an explicit
  // season match, or a confirmed continuous catalogue and an absolute number.
  static bool _titleMatches(DanmakuIdentity id, String value) {
    final candidate = _name(value);
    final title = _name(id.title);
    return (id.season <= 1 && candidate == title) ||
        (id.season >= 1 &&
            (candidate == '$title第${id.season}季' ||
                candidate == '$title第${_chinese(id.season)}季'));
  }

  Future<DanmakuTrack?> _catalogMatch(
    DanmakuIdentity id,
    Set<String> titles,
    Future<List<Json>> Function(String) search,
    String site,
  ) async {
    final tried = <String>{};
    final triedAnchors = <String>{};
    final matches = <String, DanmakuTrack>{};
    for (final pending in titles.map(search).toList()) {
      for (final row in await pending) {
        final category = row['cat_name'];
        final candidate = '${row['titleTxt'] ?? ''}';
        final sameTitle = _titleMatches(id, candidate);
        final name = _name(id.title).replaceFirst(RegExp(r'年番$'), '');
        final continuous =
            id.episode > 0 &&
            category == '动漫' &&
            (id.continuous ||
                id.episode >= 75 ||
                id.absolute > id.episode ||
                _name(id.title).endsWith('年番')) &&
            (_name(candidate) == '$name年番' || (_name(candidate) == name));
        if (!sameTitle && !continuous) continue;
        if (id.episode == 0 &&
            (category != '电影' ||
                id.year > 0 && integer(row['year']) != id.year)) {
          continue;
        }
        final entity = '${row['en_id'] ?? ''}';
        final cat = category == '动漫'
            ? 4
            : category == '电视剧'
            ? 2
            : 0;
        String? link;
        if (id.episode == 0) {
          link = object(row['playlinks'])[site]?.toString();
        } else {
          final number = continuous && id.absolute > 0
              ? id.absolute
              : id.episode;
          if (continuous &&
              id.season > 1 &&
              number < 75 &&
              id.absolute <= id.episode &&
              !id.continuous) {
            continue;
          }
          if (cat == 0 ||
              tried.length >= 5 ||
              !RegExp(r'^[\w-]{1,64}$').hasMatch(entity) ||
              !tried.add('$entity:$number')) {
            continue;
          }
          final json = await _available(
            () => _json('api.web.360kan.com', '/v1/detail', {
              'cat': '$cat',
              'id': entity,
              'site': site,
              'start': '$number',
              'end': '$number',
            }),
          );
          final data = object(json?['data']);
          final verifiedCatalogue =
              !continuous ||
              (integer(object(data['allupinfo'])[site]) >= 75 &&
                  _name('${data['title']}') == _name(candidate));
          if (!verifiedCatalogue && site != 'bilibili1') continue;
          final episodes = objects(
            object(data['allepidetail'])[site],
          ).where((e) => integer(e['playlink_num']) == number).toList();
          if (verifiedCatalogue && episodes.length == 1) {
            link = episodes.single['url']?.toString();
          }
          if (site == 'bilibili1' && _publicVideo(link, site) == null) {
            final anchor = _publicVideo(
              object(row['playlinks'])[site]?.toString(),
              site,
            );
            if (anchor != null && triedAnchors.add(anchor)) {
              final track = await _available(
                () => _bilibiliSeason(
                  id,
                  {'ep_id': anchor},
                  episodeNumber: number,
                  expectedTitle: candidate,
                  continuous: continuous && !sameTitle,
                ),
              );
              if (track != null) matches[anchor] = track;
              if (matches.length > 1) return null;
            }
            continue;
          }
        }
        final video = _publicVideo(link, site);
        if (video == null || matches.containsKey(video)) continue;
        final track = await _available(
          () => switch (site) {
            'qq' => _tencent(id, video),
            'qiyi' => _iqiyi(id, video),
            'imgo' => _mango(id, video),
            _ => _bilibiliSeason(id, {'ep_id': video}, explicit: true),
          },
        );
        if (track != null) matches[video] = track;
        if (matches.length > 1) return null;
      }
    }
    return matches.values.firstOrNull;
  }

  static String? _publicVideo(String? link, String site) {
    final uri = Uri.tryParse(link ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.port != 443 ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final pattern = switch (site) {
      'qq' when uri.host == 'v.qq.com' =>
        r'^/x/(?:cover/[\w]+/|page/)([a-zA-Z0-9]{6,24})\.html$',
      'qiyi' when uri.host == 'www.iqiyi.com' =>
        r'^/v_([a-zA-Z0-9]{1,32})\.html$',
      'imgo' when uri.host == 'www.mgtv.com' =>
        r'^/b/(\d{1,12}/\d{1,12})\.html$',
      'bilibili1'
          when {'www.bilibili.com', 'bilibili.com'}.contains(uri.host) =>
        r'^/(?:zh-Hans/|zh-Hant/)?bangumi/play/ep(\d{1,16})/?$',
      _ => null,
    };
    return pattern == null
        ? null
        : RegExp(pattern).firstMatch(uri.path)?.group(1);
  }

  Future<DanmakuTrack?> _mango(DanmakuIdentity id, String key) async {
    final [cid, vid] = key.split('/');
    return DanmakuTrack(
      '芒果 TV',
      List.generate((id.seconds / 60).ceil(), (i) {
        final start = i * 60.0, end = (i + 1) * 60.0;
        return (
          start: start,
          end: end,
          load: () async {
            final json = await _json('galaxy.bz.mgtv.com', '/rdbarrage', {
              'version': '2.0.0',
              'vid': vid,
              'cid': cid,
              'time': '${i * 60000}',
              'abroad': '0',
              'platform': '0',
            });
            return objects(object(json['data'])['items'])
                .take(5000)
                .map(
                  (row) => _comment(
                    _number(row['time']) / 1000,
                    row['content'],
                    1,
                    0xffffff,
                  ),
                )
                .nonNulls
                .where((row) => row.time >= start && row.time < end)
                .toList();
          },
        );
      }),
      link: 'https://www.mgtv.com/b/$key.html',
    );
  }

  Future<DanmakuTrack?> _tencentSearch(
    DanmakuIdentity id,
    Set<String> titles,
  ) async {
    final base = _name(id.title).replaceFirst(RegExp(r'年番$'), '');
    final annual = _name(id.title).endsWith('年番');
    final queries = {if (id.continuous || annual) '$base 年番', ...titles};
    for (final query in queries.take(3)) {
      final response = await _available(
        () async => object(
          jsonDecode(
            utf8.decode(
              await _bytes(
                Uri.https(
                  'pbaccess.video.qq.com',
                  '/trpc.videosearch.mobile_search.MultiTerminalSearch/MbSearch',
                  {'vplatform': '2'},
                ),
                body: {
                  'version': '25071701',
                  'clientType': 1,
                  'query': query,
                  'pagenum': 0,
                  'pagesize': 20,
                  'isneedQc': true,
                  'extraInfo': {
                    'multi_terminal_pc': '1',
                    'themeType': '1',
                    'sugRelatedIds': '{}',
                  },
                },
              ),
            ),
          ),
        ),
      );
      if (response?['ret']?.toString() != '0') continue;
      final data = object(response?['data']);
      final boxes = [
        object(data['normalList']),
        ...objects(data['areaBoxList']).take(6),
      ];
      final matches = <String>{};
      final covers = <String, bool>{};
      for (final entry in boxes.expand(
        (box) => objects(box['itemList']).take(24),
      )) {
        final cover = '${object(entry['doc'])['id'] ?? ''}';
        final info = object(entry['videoInfo']);
        final title = '${info['title'] ?? ''}'.replaceAll(
          RegExp(r'<[^>]*>'),
          '',
        );
        final type = integer(info['videoType']);
        final exact = _titleMatches(id, title);
        final continuous =
            type == 3 &&
            (id.continuous || annual || id.episode >= 75) &&
            _name(title) == '$base年番';
        if (!{2, 3}.contains(type) ||
            !RegExp(r'^[a-zA-Z0-9]{6,24}$').hasMatch(cover) ||
            (annual && !_name(title).endsWith('年番')) ||
            (!exact && !continuous)) {
          continue;
        }
        covers[cover] = exact;
        for (final site in objects(info['episodeSites']).take(8)) {
          if (site['enName'] != 'qq' ||
              !exact && integer(site['totalEpisode']) < 75) {
            continue;
          }
          for (final episode in objects(site['episodeInfoList']).take(200)) {
            final link = '${episode['url'] ?? ''}';
            final vid = _publicVideo(link, 'qq');
            final seconds = _number(episode['duration']);
            if (vid != null &&
                vid == '${episode['id']}' &&
                Uri.parse(link).path == '/x/cover/$cover/$vid.html' &&
                integer(episode['title']) == id.episode &&
                seconds > 90 &&
                danmakuDurationMatches(id.seconds, seconds)) {
              matches.add(vid);
            }
          }
        }
      }
      if (matches.length == 1) {
        final track = await _available(() => _tencent(id, matches.single));
        if (track != null) return track;
      }
      if (matches.isEmpty) {
        final fallback = (await Future.wait(
          covers.entries
              .take(2)
              .map(
                (entry) => _available(
                  () => _tencentCover(id, entry.key, entry.value, base),
                ),
              ),
        )).nonNulls.toSet();
        if (fallback.length == 1) {
          final track = await _available(() => _tencent(id, fallback.single));
          if (track != null) return track;
        }
      }
    }
    return null;
  }

  Future<String?> _tencentCover(
    DanmakuIdentity id,
    String cover,
    bool exact,
    String base,
  ) async {
    Future<Json> page([Map<String, String> context = const {}]) async => object(
      jsonDecode(
        utf8.decode(
          await _bytes(
            Uri.https(
              'pbaccess.video.qq.com',
              '/trpc.vector_layout.page_view.PageService/getPage',
              {'video_appid': '3000010', 'vversion_platform': '2'},
            ),
            body: {
              'page_params': {
                ...context,
                'req_from': 'web_vsite',
                'cid': cover,
                'vid': '',
              },
              'page_bypass_params': {
                'scene': 'desk_detail',
                'params': {'caller_id': '3000010', 'platform_id': '2'},
              },
              'page_context': <String, String>{},
            },
          ),
        ),
      ),
    );
    Json card(Json page, String type) =>
        objects(
          object(page['data'])['CardList'],
        ).take(40).where((row) => row['type'] == type).firstOrNull ??
        {};
    Iterable<Json> rows(Json card) => object(card['children_list']).values
        .take(200)
        .expand((child) => objects(object(child)['cards']).take(12))
        .map((row) => object(row['params']));
    Set<String> pick(Json list) => rows(list)
        .where(
          (row) =>
              row['cid'] == cover &&
              integer(row['title']) == id.episode &&
              RegExp(r'^[a-zA-Z0-9]{6,24}$').hasMatch('${row['vid']}') &&
              _number(row['duration']) > 90 &&
              danmakuDurationMatches(id.seconds, _number(row['duration'])),
        )
        .map((row) => '${row['vid']}')
        .toSet();
    final first = await page();
    final info = rows(card(first, 'pc_introduction')).firstOrNull ?? {};
    final title = '${info['title'] ?? ''}';
    if (!(exact && _titleMatches(id, title)) &&
        (integer(info['type']) != 3 ||
            integer(info['episode_all']) < 75 ||
            _name(title) != '$base年番')) {
      return null;
    }
    final list = card(first, 'pc_web_episode_list');
    var candidates = pick(list);
    final tabs = '${object(list['params'])['tabs'] ?? ''}';
    if (candidates.isEmpty && tabs.isNotEmpty && tabs.length <= 65536) {
      final range = objects(jsonDecode(tabs))
          .take(200)
          .where(
            (row) =>
                integer(row['begin']) <= id.episode &&
                integer(row['end']) >= id.episode,
          )
          .firstOrNull;
      final encoded = '${range?['page_context'] ?? ''}';
      if (encoded.length <= 4096 && encoded.split('&').contains('cid=$cover')) {
        final context = Uri.splitQueryString(encoded);
        candidates = pick(card(await page(context), 'pc_web_episode_list'));
      }
    }
    return candidates.length == 1 ? candidates.single : null;
  }

  Future<DanmakuTrack?> _tencent(DanmakuIdentity id, String video) async {
    final json = await _json('dm.video.qq.com', '/barrage/base/$video');
    final index = json['segment_index'];
    final rows = index is List ? index : object(index).values;
    final segments = <DanmakuSegment>[];
    for (final value in rows.take(3000)) {
      final row = object(value);
      final path = '${row['segment_name'] ?? ''}';
      if (!RegExp(r'^(?:t/v1/)?\d{1,9}/\d{1,9}$').hasMatch(path)) continue;
      final start = integer(row['segment_start']) / 1000;
      final end = integer(path.split('/').last) / 1000;
      if (start < 0 || end <= start || end > 86460) continue;
      segments.add((
        start: start,
        end: end,
        load: () async {
          final json = await _json(
            'dm.video.qq.com',
            '/barrage/segment/$video/$path',
          );
          return objects(json['barrage_list'])
              .take(5000)
              .map((row) {
                Json style = {};
                final raw = row['content_style'];
                if (raw is String && raw.length <= 2048) {
                  try {
                    style = object(jsonDecode(raw));
                  } on FormatException {
                    /* Default style. */
                  }
                }
                return _comment(
                  _number(row['time_offset']) / 1000,
                  row['content'],
                  switch (integer(style['position'])) {
                    2 => 5,
                    3 => 4,
                    _ => 1,
                  },
                  _color(style['color']),
                );
              })
              .nonNulls
              .where((c) => c.time >= start && c.time < end)
              .toList();
        },
      ));
    }
    if (segments.isEmpty ||
        !danmakuDurationMatches(
          id.seconds,
          segments.map((s) => s.end).reduce((a, b) => a > b ? a : b),
        )) {
      return null;
    }
    return DanmakuTrack(
      '腾讯视频',
      segments,
      link: 'https://v.qq.com/x/page/$video.html',
    );
  }

  Future<DanmakuTrack?> _iqiyi(DanmakuIdentity id, String video) async {
    final digits = RegExp(r'^\d{1,20}$');
    var tvId = video;
    if (!digits.hasMatch(tvId)) {
      final decoded = await _json('pcw-api.iq.com', '/api/decode/$video', {
        'platformId': '3',
        'modeCode': 'intl',
        'langCode': 'sg',
      });
      tvId = '${decoded['data'] ?? ''}';
    }
    if (!digits.hasMatch(tvId)) return null;
    final json = await _json(
      'pcw-api.iqiyi.com',
      '/video/video/baseinfo/$tvId',
    );
    final info = object(json['data']);
    final seconds = integer(info['durationSec']);
    if (!danmakuDurationMatches(id.seconds, seconds) ||
        info['displayBarrage'] == false) {
      return null;
    }
    final tail = tvId
        .padLeft(4, '0')
        .substring(tvId.padLeft(4, '0').length - 4);
    return DanmakuTrack(
      '爱奇艺',
      List.generate((seconds / 60).ceil(), (i) {
        final key = '${tvId}_60_${i + 1}';
        final hash = md5
            .convert(ascii.encode('${key}cbzuw1259a'))
            .toString()
            .substring(24);
        final start = i * 60.0, end = (i + 1) * 60.0;
        return (
          start: start,
          end: end,
          load: () async {
            final data = await _bytes(
              Uri.https(
                'cmts.iqiyi.com',
                '/bullet/${tail.substring(0, 2)}/${tail.substring(2)}/${key}_$hash.br',
              ),
            );
            return (await compute(
              _iqiyiComments,
              data,
            )).where((c) => c.time >= start && c.time <= end).toList();
          },
        );
      }),
      link: 'https://www.iqiyi.com/v_$video.html',
    );
  }

  Future<DanmakuTrack?> _bilibiliFamily(
    DanmakuIdentity id,
    Future<List<Json>> Function(String) search,
  ) async {
    final seed = <String>{};
    final publicCatalog = search(id.title);
    final root = await _available(
      () => _json('api.bilibili.com', '/x/web-interface/search/type', {
        'search_type': 'media_bangumi',
        'keyword': id.title,
      }),
    );
    for (final row in objects(object(root?['data'])['result']).take(15)) {
      final name = '${row['title'] ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), '');
      final sid = integer(row['season_id']);
      if (sid > 0 &&
          (_name(name) == _name(id.title) || _titleMatches(id, name))) {
        seed.add('season_id=$sid');
      }
    }
    for (final row in await publicCatalog) {
      if (_name('${row['titleTxt']}') != _name(id.title) &&
          !_titleMatches(id, '${row['titleTxt']}')) {
        continue;
      }
      final ep = _publicVideo(
        object(row['playlinks'])['bilibili1']?.toString(),
        'bilibili1',
      );
      if (ep != null) seed.add('ep_id=$ep');
    }
    Future<Json> read(Map<String, String> query) async => object(
      (await _available(
        () => _json('api.bilibili.com', '/pgc/view/web/season', query),
      ))?['result'],
    );
    final related = <int>{};
    final seriesType = <int>{};
    for (final show in await Future.wait(
      seed.take(4).map((value) {
        final [key, number] = value.split('=');
        return read({key: number});
      }),
    )) {
      final title = '${show['title']}';
      if (_name(title) != _name(id.title) && !_titleMatches(id, title)) {
        continue;
      }
      final type = integer(show['type']);
      if (type == 2) continue;
      if (type > 0) seriesType.add(type);
      for (final season in objects(show['seasons']).take(16)) {
        final name = '${season['season_title'] ?? ''}';
        final sid = integer(season['season_id']);
        if (sid > 0 && !RegExp(r'配音|配版|总集|總集').hasMatch(name)) related.add(sid);
      }
    }
    final choices = <int, (Json, int, double)>{};
    for (final show in await Future.wait(
      related.take(6).map((sid) => read({'season_id': '$sid'})),
    )) {
      final type = integer(show['type']);
      if (type == 2 || (seriesType.isNotEmpty && !seriesType.contains(type))) {
        continue;
      }
      final exact = _titleMatches(id, '${show['title']}');
      for (final row in objects(show['episodes']).take(2000)) {
        final cid = integer(row['cid']);
        final seconds = integer(row['duration']) / 1000;
        final difference = (id.seconds - seconds).abs();
        if (cid < 1 ||
            _biliEpisode(row) != id.episode ||
            _preview(row) ||
            !danmakuDurationMatches(id.seconds, seconds) ||
            (!exact && difference > 5)) {
          continue;
        }
        choices[cid] = (row, exact ? 1 : 0, difference);
      }
    }
    final ranked = choices.values.toList()
      ..sort(
        (a, b) => a.$2 == b.$2 ? a.$3.compareTo(b.$3) : b.$2.compareTo(a.$2),
      );
    if (ranked.isEmpty ||
        (ranked.length > 1 &&
            ranked[0].$2 == ranked[1].$2 &&
            ranked[1].$3 - ranked[0].$3 < (ranked[0].$2 == 0 ? 14 : 5))) {
      return null;
    }
    return _biliTrack(ranked.first.$1);
  }

  Future<DanmakuTrack?> _bilibiliSearch(
    DanmakuIdentity id,
    Set<String> titles,
  ) async {
    final matches = await _bilibiliCandidates(id, titles);
    return matches.length == 1 ? matches.single : null;
  }

  Future<List<DanmakuTrack>> _bilibiliCandidates(
    DanmakuIdentity id,
    Set<String> titles,
  ) async {
    final candidates = <int>{};
    final matches = <Future<DanmakuTrack?>>[];
    final queries = titles
        .where((title) => !title.endsWith(' 年番'))
        .map(
          (title) => _available(
            () => _json('api.bilibili.com', '/x/web-interface/search/type', {
              'search_type': id.episode == 0 ? 'media_ft' : 'media_bangumi',
              'keyword': title,
            }),
          ),
        )
        .toList();
    for (final query in queries) {
      final json = await query;
      for (final row in objects(object(json?['data'])['result']).take(15)) {
        if (!_titleMatches(
          id,
          '${row['title'] ?? ''}'.replaceAll(RegExp(r'<[^>]*>'), ''),
        )) {
          continue;
        }
        if (id.year > 0 && id.year != _biliYear(row['pubtime'])) continue;
        final sid = integer(row['season_id']);
        if (sid < 1 || candidates.length >= 4 || !candidates.add(sid)) continue;
        matches.add(
          _available(() => _bilibiliSeason(id, {'season_id': '$sid'})),
        );
      }
      if (candidates.length >= 4) break;
    }
    return (await Future.wait(matches)).nonNulls.toList();
  }

  static int _biliYear(Object? time) {
    final seconds = integer(time);
    return seconds > 0 && seconds < 5000000000
        ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).year
        : 0;
  }

  static int _biliEpisode(Json row) => integer(
    RegExp(
      r'^\s*(?:第\s*)?(\d+)\s*(?:[话話集]|$)',
    ).firstMatch('${row['title'] ?? ''}')?.group(1),
  );

  static bool _preview(Json row) => RegExp(
    r'预告|預告|花絮|特辑|特輯|总集篇|總集篇',
  ).hasMatch('${row['badge']} ${row['long_title']} ${row['title']}');

  Future<DanmakuTrack?> _bilibiliSeason(
    DanmakuIdentity id,
    Map<String, String> query, {
    bool explicit = false,
    int? episodeNumber,
    String? expectedTitle,
    bool continuous = false,
  }) async {
    final json = await _json('api.bilibili.com', '/pgc/view/web/season', query);
    final result = object(json['result']);
    final rows = objects(result['episodes']);
    if (expectedTitle != null &&
        (_name('${result['title'] ?? ''}') != _name(expectedTitle) ||
            (continuous &&
                rows.where((row) => _biliEpisode(row) >= 75).isEmpty))) {
      return null;
    }
    final matches = rows
        .where(
          (row) => explicit
              ? '${row['id']}' == query['ep_id']
              : id.episode == 0
              ? rows.length == 1
              : _biliEpisode(row) == (episodeNumber ?? id.episode),
        )
        .where(
          (row) =>
              !_preview(row) &&
              integer(row['cid']) > 0 &&
              danmakuDurationMatches(
                id.seconds,
                integer(row['duration']) / 1000,
              ),
        )
        .toList();
    if (matches.length != 1) return null;
    return _biliTrack(
      matches.single,
      epId: query['ep_id'],
      title: result['title']?.toString(),
    );
  }

  DanmakuTrack _biliTrack(Json row, {String? epId, String? title}) {
    final cid = integer(row['cid']);
    final seconds = integer(row['duration']) / 1000;
    final episode = integer(row['id']) > 0 ? '${row['id']}' : epId;
    Future<List<DanmakuComment>>? xml;
    Future<List<DanmakuComment>> readXml() async {
      for (final uri in [
        Uri.https('api.bilibili.com', '/x/v1/dm/list.so', {'oid': '$cid'}),
        Uri.https('comment.bilibili.com', '/$cid.xml'),
      ]) {
        final rows = await _available(
          () async => compute(_biliXml, await _bytes(uri)),
        );
        if (rows != null && rows.isNotEmpty) return rows;
      }
      throw const FormatException('公开弹幕 XML 暂不可读');
    }

    Future<List<DanmakuComment>> slice(double start, double end) async {
      final request = xml ??= readXml();
      try {
        return (await request)
            .where((c) => c.time >= start && c.time < end)
            .toList();
      } catch (_) {
        if (identical(xml, request)) xml = null;
        rethrow;
      }
    }

    return DanmakuTrack(
      '哔哩哔哩',
      List.generate((seconds / 360).ceil(), (i) {
        final start = i * 360.0, end = (i + 1) * 360.0;
        return (
          start: start,
          end: end,
          load: () async {
            try {
              final key = 'bili-segment:$cid:${i + 1}';
              final cache = storage;
              final generation = cacheGeneration;
              final cached = await cache?.read(key);
              if (cached != null) {
                final rows = await _available(
                  () => compute(_biliComments, cached),
                );
                if (rows != null && rows.isNotEmpty) return rows;
              }
              final body = await _bytes(
                Uri.https('api.bilibili.com', '/x/v2/dm/web/seg.so', {
                  'type': '1',
                  'oid': '$cid',
                  'segment_index': '${i + 1}',
                }),
              );
              final comments = await compute(_biliComments, body);
              if (comments.isNotEmpty) {
                if (cache != null) {
                  unawaited(cache.write(key, body, generation));
                }
                return comments;
              }
            } catch (_) {
              /* A public XML feed may still be available. */
            }
            return slice(start, end);
          },
        );
      }),
      link: episode == null
          ? null
          : 'https://www.bilibili.com/bangumi/play/ep$episode',
      label: [
        '哔哩哔哩',
        title,
        row['long_title']?.toString(),
      ].nonNulls.where((value) => value.isNotEmpty).join(' · '),
      supplements: List.generate(
        (seconds / 360).ceil(),
        (i) => (
          start: i * 360.0,
          end: (i + 1) * 360.0,
          load: () => slice(i * 360.0, (i + 1) * 360.0),
        ),
      ),
    );
  }

  static Uri? compatibleAddress(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return null;
    final host = uri.host.toLowerCase().replaceFirst(RegExp(r'\.+$'), '');
    final loopback =
        host == 'localhost' ||
        host == '::1' ||
        InternetAddress.tryParse(host)?.isLoopback == true;
    if ((uri.scheme != 'https' && !(uri.scheme == 'http' && loopback)) ||
        host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        {'dandanplay.net', 'dandanplay.com', 'api.danmu.icu'}.contains(host) ||
        host.endsWith('.dandanplay.net') ||
        host.endsWith('.dandanplay.com')) {
      return null;
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    return uri.replace(
      path: path.endsWith('/api/v2') ? '$path/' : '$path/api/v2/',
    );
  }

  static List<Uri> compatibleAddresses(String value) => value
      .split(RegExp(r'[\r\n]+'))
      .take(12)
      .where((line) => line.length <= 512)
      .map(compatibleAddress)
      .nonNulls
      .toSet()
      .take(5)
      .toList();

  Future<DanmakuTrack?> _compatible(DanmakuIdentity id, Uri api) async {
    final search = api
        .resolve('search/episodes')
        .replace(
          queryParameters: {
            'anime': id.title,
            if (id.episode > 0) 'episode': '${id.episode}',
          },
        );
    final json = object(jsonDecode(utf8.decode(await _bytes(search))));
    final matches = <int>{};
    for (final anime in objects(json['animes']).take(30)) {
      if (!_titleMatches(id, '${anime['animeTitle'] ?? ''}')) continue;
      for (final row in objects(anime['episodes']).take(300)) {
        final label = '${row['episodeTitle'] ?? ''}';
        final episode = RegExp(
          r'^(?:第\s*)?(\d+)\s*(?:[集话話]|[\s：:.-]|$)',
        ).firstMatch(label);
        if (id.episode == 0
            ? !{'电影', '正片', id.title}.contains(label)
            : integer(episode?.group(1)) != id.episode) {
          continue;
        }
        final entry = integer(row['episodeId']);
        if (entry > 0) matches.add(entry);
      }
    }
    if (matches.length != 1) return null;
    return DanmakuTrack('兼容弹幕服务', [
      (
        start: 0.0,
        end: id.seconds.toDouble(),
        load: () async {
          final uri = api
              .resolve('comment/${matches.single}')
              .replace(queryParameters: {'withRelated': 'false'});
          final body = object(jsonDecode(utf8.decode(await _bytes(uri))));
          return objects(body['comments'])
              .take(12000)
              .map((row) {
                final data = '${row['p'] ?? ''}'.split(',');
                return data.length < 3
                    ? null
                    : _comment(
                        _number(data[0]),
                        row['m'],
                        integer(data[1]),
                        integer(data[2]),
                      );
              })
              .nonNulls
              .toList();
        },
      ),
    ]);
  }
}

double _number(Object? value) => double.tryParse('$value') ?? -1;
int _color(Object? value) =>
    int.tryParse('${value ?? ''}'.replaceFirst('#', ''), radix: 16) ?? 0xffffff;
DanmakuComment? _comment(double time, Object? value, int mode, int color) {
  if (mode == 2 || mode == 3) mode = 1;
  if (!time.isFinite ||
      time < 0 ||
      time > 86400 ||
      value is! String ||
      value.length > 160) {
    return null;
  }
  final text = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.isEmpty || !{1, 4, 5}.contains(mode)
      ? null
      : DanmakuComment(time, text, mode, color & 0xffffff);
}

XmlDocument _xml(Uint8List bytes) {
  final text = utf8.decode(bytes);
  if (text.contains('<!DOCTYPE') || text.contains('<!ENTITY')) {
    throw const FormatException('弹幕 XML 不受支持');
  }
  return XmlDocument.parse(text);
}

List<DanmakuComment> _biliXml(Uint8List bytes) => _xml(bytes)
    .findAllElements('d')
    .take(12000)
    .map((row) {
      final fields = (row.getAttribute('p') ?? '').split(',');
      return fields.length < 4
          ? null
          : _comment(
              _number(fields[0]),
              row.innerText,
              integer(fields[1]),
              integer(fields[3]),
            );
    })
    .nonNulls
    .toList();

List<DanmakuComment> _iqiyiComments(Uint8List data) {
  final bytes = brotliDecode(data, maxOutputSize: 4 * 1024 * 1024);
  if (bytes.isEmpty) return [];
  if (bytes.first == 0x3c || bytes.first == 0xef) {
    return _xml(bytes)
        .findAllElements('content')
        .take(5000)
        .map((row) {
          final parent = row.parentElement;
          return _comment(
            _number(parent?.getElement('showTime')?.innerText),
            row.innerText,
            1,
            _color(parent?.getElement('color')?.innerText),
          );
        })
        .nonNulls
        .toList();
  }
  final comments = <DanmakuComment>[];
  for (final block in _fields(
    bytes,
  ).where((f) => f.key == 6 && f.value is Uint8List).take(5000)) {
    final fields = _fields(block.value as Uint8List).toList();
    final time = _text(fields.where((f) => f.key == 1).firstOrNull?.value);
    for (final item in fields.where(
      (f) => f.key == 2 && f.value is Uint8List,
    )) {
      final row = Map.fromEntries(_fields(item.value as Uint8List));
      final comment = _comment(
        _number(_text(row[6] ?? time)),
        _text(row[2]),
        1,
        _color(_text(row[8])),
      );
      if (comment != null) comments.add(comment);
      if (comments.length >= 5000) return comments;
    }
  }
  return comments;
}

String _text(Object? value) => value is Uint8List
    ? utf8.decode(value, allowMalformed: true)
    : value is String
    ? value
    : '';

List<DanmakuComment> _biliComments(Uint8List data) => _fields(data)
    .where((f) => f.key == 1 && f.value is Uint8List)
    .take(5000)
    .map((f) {
      final row = Map.fromEntries(_fields(f.value as Uint8List));
      return _comment(
        integer(row[2]) / 1000,
        _text(row[7]),
        integer(row[3]),
        integer(row[5]),
      );
    })
    .nonNulls
    .toList();

Iterable<MapEntry<int, Object>> _fields(Uint8List bytes) sync* {
  var offset = 0;
  int varint() {
    var value = 0;
    for (var shift = 0; shift < 64 && offset < bytes.length; shift += 7) {
      final next = bytes[offset++];
      value |= (next & 127) << shift;
      if (next < 128) return value;
    }
    throw const FormatException('无效弹幕字段');
  }

  while (offset < bytes.length) {
    final tag = varint();
    final key = tag >>> 3;
    if (key == 0) throw const FormatException('无效弹幕标签');
    final wire = tag & 7;
    if (wire == 0) {
      yield MapEntry(key, varint());
      continue;
    }
    final length = switch (wire) {
      1 => 8,
      2 => varint(),
      5 => 4,
      _ => -1,
    };
    if (length < 0 || length > bytes.length - offset) {
      throw const FormatException('无效弹幕长度');
    }
    if (wire == 2) {
      yield MapEntry(
        key,
        Uint8List.sublistView(bytes, offset, offset + length),
      );
    }
    offset += length;
  }
}
