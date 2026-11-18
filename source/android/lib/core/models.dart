import 'dart:convert';

typedef Json = Map<String, dynamic>;
Json object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Json> objects(dynamic value) =>
    value is List ? value.map(object).toList() : [];
int integer(dynamic value) => value is num
    ? value.isFinite
          ? value.toInt()
          : 0
    : int.tryParse('$value') ?? 0;
Duration fromTicks(dynamic value) =>
    Duration(microseconds: integer(value) ~/ 10);
int ticks(Duration value) => value.inMicroseconds * 10;

final _episodeOrdinal = RegExp(
  r'(?:^|[\s._-])S\d{1,3}E(\d{1,4})(?!\d)|第\s*(\d{1,4})\s*[集话話]',
  caseSensitive: false,
);
final _seasonOrdinal = RegExp(
  r'(?:^|[\s._-])S(\d{1,3})E\d{1,4}(?!\d)|第\s*(\d{1,3})\s*季',
  caseSensitive: false,
);
final _pathSeparator = RegExp(r'[/\\]');
final _urlSuffix = RegExp(r'[?#]');
final _episodeFileExtension = RegExp(
  r'\.(?:strm|mkv|mp4|m2ts|avi|mov|ts|webm)$',
  caseSensitive: false,
);

Set<int> episodeOrdinalsIn(String label) => _ordinalMatches(
  _episodeOrdinal,
  label,
).where((number) => number > 0).toSet();

Iterable<int> _ordinalMatches(RegExp pattern, String label) => pattern
    .allMatches(label)
    .map((match) => int.parse((match.group(1) ?? match.group(2))!));

String? _mediaBasename(Object? path) => path is String
    ? path.split(_urlSuffix).first.split(_pathSeparator).last
    : null;

typedef EpisodeDisplay = ({int? season, int? episode});
const episodeDisplayHintsKey = '_YingyuEpisodeDisplayHintsV1';

String episodeDisplayLabel(
  EpisodeDisplay numbers, {
  bool showSeason = true,
  bool compact = false,
}) => [
  if (numbers.season case final int season when showSeason)
    compact ? '${season}季' : '第 $season 季',
  if (numbers.episode case final int episode)
    compact ? '${episode}集' : '第 $episode 集',
].join(compact ? '' : ' · ');

class Session {
  const Session({
    required this.base,
    required this.userId,
    required this.token,
    required this.username,
    required this.deviceId,
    this.serverId = '',
  });
  final Uri base;
  final String userId, token, username, deviceId, serverId;
  Json toJson() => {
    'base': base.toString(),
    'userId': userId,
    'token': token,
    'username': username,
    'deviceId': deviceId,
    'serverId': serverId,
  };
  factory Session.fromJson(Json json) => Session(
    base: Uri.parse(json['base']),
    userId: json['userId'],
    token: json['token'],
    username: json['username'],
    deviceId: json['deviceId'],
    serverId: json['serverId'] ?? '',
  );
  String encode() => jsonEncode(toJson());
}

class MediaItem {
  MediaItem(this.data);
  final Json data;
  String get id => data['Id']?.toString() ?? '';
  String get title => data['Name']?.toString() ?? '未命名';
  String get type => data['Type']?.toString() ?? '';
  bool get series => type == 'Series';
  bool get folder => data['IsFolder'] == true || series || type == 'Season';
  bool get playable =>
      !folder &&
      (type == 'Movie' || type == 'Episode' || data['MediaType'] == 'Video');
  String get overview =>
      (data['Overview']?.toString() ?? '').replaceAll(RegExp('<[^>]+>'), '');
  String get year => data['ProductionYear']?.toString() ?? '';
  String get rating =>
      data['CommunityRating'] is num &&
          (data['CommunityRating'] as num).isFinite
      ? (data['CommunityRating'] as num).toStringAsFixed(1)
      : '';
  String get imageTag => object(data['ImageTags'])['Primary']?.toString() ?? '';
  String get backdropTag =>
      (data['BackdropImageTags'] is List &&
          (data['BackdropImageTags'] as List).isNotEmpty)
      ? data['BackdropImageTags'][0].toString()
      : '';
  Duration get duration => fromTicks(data['RunTimeTicks']);

  /// Display-only fallback for a title with a single advertised version.
  Duration get watchDuration {
    final runtime = duration;
    if (runtime > Duration.zero) return runtime;
    final sources = data['MediaSources'];
    if (sources is! List || sources.length != 1) return Duration.zero;
    return fromTicks(object(sources.single)['RunTimeTicks']);
  }

  Duration get resume =>
      fromTicks(object(data['UserData'])['PlaybackPositionTicks']);

  /// Read-only display inference. Never replace the server's episode identity.
  EpisodeDisplay episodeDisplay({MediaItem? catalogue}) {
    if (type != 'Episode') return (season: null, episode: null);
    final entries = [
      this,
      if (catalogue != null && id.isNotEmpty && catalogue.id == id) catalogue,
    ];
    final structured = entries.map((entry) => entry.data);
    final labels = [
      for (final entry in entries) ...[
        if (entry.data['Name'] case final String name) name,
        if (entry.data['OriginalTitle'] case final String name) name,
        ?_mediaBasename(entry.data['Path']),
      ],
    ];
    final sources = [
      for (final entry in entries)
        for (final source in objects(entry.data['MediaSources'])) ...[
          if (source['Name'] case final String name) name,
          ?_mediaBasename(source['Path']),
        ],
    ];
    int? read(String key, int minimum, Iterable<int> Function(String) parse) {
      for (final data in structured) {
        final value = int.tryParse('${data[key]}');
        if (value != null && value >= minimum) return value;
      }
      for (final label in labels) {
        final numbers = parse(label).toSet();
        if (numbers.isNotEmpty) {
          return numbers.length == 1 ? numbers.single : null;
        }
      }
      final numbers = {
        ...sources.expand(parse),
        for (final entry in entries)
          if (object(entry.data[episodeDisplayHintsKey])[key]
              case final int number when number >= minimum)
            number,
      };
      return numbers.length == 1 ? numbers.single : null;
    }

    return (
      season: read(
        'ParentIndexNumber',
        0,
        (label) => _ordinalMatches(_seasonOrdinal, label),
      ),
      episode: read('IndexNumber', 1, episodeOrdinalsIn),
    );
  }

  String episodeDisplayTitle(EpisodeDisplay numbers) {
    final name = title.trim();
    final series = data['SeriesName']?.toString().trim() ?? '';
    final fileStyle =
        episodeOrdinalsIn(name).isNotEmpty ||
        (series.isNotEmpty && name.startsWith(series)) ||
        _episodeFileExtension.hasMatch(name);
    if (!fileStyle && name.isNotEmpty && name != '未命名') return name;
    final label = episodeDisplayLabel(numbers, showSeason: false);
    return label.isEmpty ? '分集' : label;
  }

  String get resumeDisplayTitle {
    if (type != 'Episode') return title;
    final series = data['SeriesName']?.toString().trim() ?? '';
    return series.isEmpty ? episodeDisplayTitle(episodeDisplay()) : series;
  }

  String get subtitle => type == 'Episode'
      ? [
          '${data['SeriesName'] ?? ''}',
          episodeDisplayLabel(episodeDisplay()),
        ].where((part) => part.isNotEmpty).join(' · ')
      : [
          year,
          if (duration.inMinutes > 0) '${duration.inMinutes} 分钟',
          if (rating.isNotEmpty) '★ $rating',
        ].where((e) => e.isNotEmpty).join(' · ');
}

class ItemPage {
  ItemPage(this.items, this.total, {this.countKnown = true});
  final List<MediaItem> items;
  final int total;
  final bool countKnown;
  factory ItemPage.fromJson(Json json) => ItemPage(
    objects(json['Items']).map(MediaItem.new).toList(),
    integer(json['TotalRecordCount']),
    countKnown:
        json['Items'] is List &&
        (json['Items'] as List).every((value) => value is Map) &&
        json['TotalRecordCount'] is int &&
        (json['TotalRecordCount'] as int) >= 0,
  );
}

enum DiscKind { none, iso, blurayFolder }

DiscKind discAddressKind(String address) {
  final uri = Uri.tryParse(address);
  final path = (uri?.path ?? address).replaceAll('\\', '/').toLowerCase();
  if (path.endsWith('.iso') || path.endsWith('.udf')) return DiscKind.iso;
  if (RegExp(
    r'/bdmv(?:/(?:index\.bdmv|movieobject\.bdmv)?)?$',
  ).hasMatch(path)) {
    return DiscKind.blurayFolder;
  }
  return DiscKind.none;
}

DiscKind discSourceKind(Json source) {
  final path = discAddressKind(source['Path']?.toString() ?? '');
  final direct = discAddressKind(source['DirectStreamUrl']?.toString() ?? '');
  if (path != DiscKind.none) return path;
  if (direct != DiscKind.none) return direct;
  final container = source['Container']?.toString().toLowerCase();
  final type = source['VideoType']?.toString().toLowerCase();
  if (type == 'iso' || container == 'iso' || container == 'udf') {
    return DiscKind.iso;
  }
  if (type == 'bluray' || container == 'bdmv') return DiscKind.blurayFolder;
  return DiscKind.none;
}

class PlaybackRoute {
  PlaybackRoute({
    required this.url,
    required this.sourceId,
    required this.sessionId,
    required this.headers,
    required this.streams,
    this.serverBase,
    this.playMethod = 'DirectStream',
    this.diagnosticCanonicalUrl,
    this.sameOriginHeaders = const {},
    this.diagnosticSecrets = const [],
    this.discKind = DiscKind.none,
    this.discFolderUrl,
    this.defaultAudioIndex,
    this.defaultSubtitleIndex,
    this.sourceDuration = Duration.zero,
  });
  final String url, sourceId, sessionId;
  final Map<String, String> headers;
  final List<Json> streams;
  final Uri? serverBase;
  // Confirmed by the opening transport before the first progress report.
  String playMethod;
  final String? diagnosticCanonicalUrl;
  // Consumed only by the origin-scoped Dart transport, never by libmpv.
  final Map<String, String> sameOriginHeaders;
  final List<String> diagnosticSecrets;
  final DiscKind discKind;
  final String? discFolderUrl;
  final int? defaultAudioIndex, defaultSubtitleIndex;
  final Duration sourceDuration;
}

class AppFailure implements Exception {
  const AppFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => status == null ? message : '$message（HTTP $status）';
}

String safeError(Object error) {
  var text = error.toString().replaceAll(
    RegExp(r'https?://[^\s<>]+', caseSensitive: false),
    '[媒体地址已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'^(?:authorization|proxy-authorization|cookie|set-cookie|x-emby-authorization|x-emby-token)\s*:[^\r\n]*',
      caseSensitive: false,
      multiLine: true,
    ),
    '[认证头已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'(api_key|token|password|pw|DeviceId|PlaySessionId)\s*[:=]\s*[^\s&,]+',
      caseSensitive: false,
    ),
    '[敏感参数已隐藏]',
  );
  return text.length > 500 ? '${text.substring(0, 500)}…' : text;
}
