import 'dart:convert';

typedef Json = Map<String, dynamic>;
Json object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Json> objects(dynamic value) =>
    value is List ? value.map(object).toList() : [];
int integer(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
Duration fromTicks(dynamic value) =>
    Duration(microseconds: integer(value) ~/ 10);
int ticks(Duration value) => value.inMicroseconds * 10;

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
  String get rating => data['CommunityRating'] is num
      ? (data['CommunityRating'] as num).toStringAsFixed(1)
      : '';
  String get imageTag => object(data['ImageTags'])['Primary']?.toString() ?? '';
  String get backdropTag =>
      (data['BackdropImageTags'] is List &&
          (data['BackdropImageTags'] as List).isNotEmpty)
      ? data['BackdropImageTags'][0].toString()
      : '';
  Duration get duration => fromTicks(data['RunTimeTicks']);
  Duration get resume =>
      fromTicks(object(data['UserData'])['PlaybackPositionTicks']);
  String get subtitle => type == 'Episode'
      ? '${data['SeriesName'] ?? ''} · 第 ${data['ParentIndexNumber'] ?? '?'} 季 第 ${data['IndexNumber'] ?? '?'} 集'
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
