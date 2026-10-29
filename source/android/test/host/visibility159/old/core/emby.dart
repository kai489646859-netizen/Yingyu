import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../version.dart';
import 'models.dart';
import 'log.dart';
import 'http_diagnostics.dart';
import 'background_work.dart';
import 'server_connection.dart';
import 'image_identity.dart';

dynamic _decodeMetadata(List<int> bytes) => jsonDecode(utf8.decode(bytes));

// Log only allowlisted operation names, never a URL, search text or real ID.
String metadataOperation(Uri uri) {
  final path = uri.path.toLowerCase();
  if (path.endsWith('/playbackinfo')) return '播放信息';
  if (path.endsWith('/authenticatebyname')) return '登录';
  if (path.contains('/sessions/playing')) return '播放进度上报';
  if (path.endsWith('/userdata')) return '观看状态写入';
  if (path.contains('/playeditems/')) return '已看状态';
  if (path.contains('/favoriteitems/')) return '收藏状态';
  if (path.endsWith('/views')) return '媒体库入口';
  if (path.endsWith('/items/resume')) return '继续观看列表';
  if (path.endsWith('/items/latest')) return '最新影片列表';
  if (RegExp(r'/items/[^/]+$').hasMatch(path)) return '影片详情';
  if (path.endsWith('/items')) {
    if (uri.queryParameters.containsKey('SearchTerm')) return '影片搜索';
    if (uri.queryParameters.containsKey('Ids')) return '资源批量核对';
    if (uri.queryParameters.containsKey('Filters')) return '个人影片列表';
    return '媒体目录';
  }
  if (path.endsWith('/episodes')) return '分集目录';
  if (path.endsWith('/seasons')) return '季目录';
  if (RegExp(r'/users/[^/]+$').hasMatch(path)) return '账户连接核对';
  return '资料接口';
}

String newId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Fewer existence calls while keeping GET URLs bounded for reverse proxies.
Iterable<List<String>> itemLookupBatches(Iterable<String> ids) sync* {
  var batch = <String>[];
  var length = 0;
  for (final id in ids) {
    final encodedLength = Uri.encodeQueryComponent(id).length + 3;
    if (batch.isNotEmpty &&
        (batch.length == 500 || length + encodedLength > 5500)) {
      yield batch;
      batch = [];
      length = 0;
    }
    batch.add(id);
    length += encodedLength;
  }
  if (batch.isNotEmpty) yield batch;
}

Uri normalizeServer(String address) {
  var value = address.trim();
  if (!value.contains('://')) value = 'http://$value';
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const AppFailure('请输入有效的 HTTP 或 HTTPS 服务器地址，可包含反向代理路径');
  }
  var path = uri.path.replaceAll(RegExp(r'/+$'), '');
  if (!path.toLowerCase().endsWith('/emby')) path += '/emby';
  return uri.replace(path: path);
}

Uri resolveMediaUri(Uri base, String address) =>
    base.replace(path: '${base.path}/').resolve(address);

// Resolve ordinary relative media addresses without re-encoding their query or
// path. Signed URLs must not pass through Uri.queryParameters reconstruction.
String resolveMediaAddress(Uri base, String address) {
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(address)) {
    throw const AppFailure('媒体源地址含有控制字符');
  }
  final parsed = Uri.tryParse(address);
  if (parsed == null) throw const AppFailure('媒体源地址无效');
  String result;
  if (parsed.hasScheme) {
    result = address;
  } else if (address.startsWith('//')) {
    result = '${base.scheme}:$address';
  } else if (address.startsWith('/')) {
    result = '${base.origin}$address';
  } else if (!parsed.pathSegments.any((p) => p == '.' || p == '..') &&
      parsed.path.isNotEmpty) {
    result = '${base.toString()}/$address';
  } else {
    final resolved = resolveMediaUri(base, address).toString();
    final suffix = address.indexOf(RegExp(r'[?#]'));
    result = suffix < 0
        ? resolved
        : '${resolved.split(RegExp(r'[?#]')).first}${address.substring(suffix)}';
  }
  final uri = Uri.parse(result);
  if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
    throw const AppFailure('媒体源地址协议不受支持');
  }
  return result;
}

const plainEmbyStreamParameters = {
  'api_key',
  'static',
  'mediasourceid',
  'playsessionid',
  'deviceid',
  'tag',
  'etag',
  'x-emby-client',
  'x-emby-device-name',
  'x-emby-device-id',
  'x-emby-client-version',
  'x-emby-token',
};

bool isPlainEmbyOriginal(Uri uri, Uri base) {
  if (uri.origin != base.origin ||
      !RegExp(
        r'/videos/[^/]+/(?:stream|original)(?:\.[^/]+)?$',
        caseSensitive: false,
      ).hasMatch(uri.path)) {
    return false;
  }
  try {
    return uri.query
        .split('&')
        .where((p) => p.isNotEmpty)
        .every(
          (pair) => plainEmbyStreamParameters.contains(
            Uri.decodeQueryComponent(pair.split('=').first).toLowerCase(),
          ),
        );
  } on FormatException {
    return false;
  }
}

bool canUseAccountHeaders(Uri uri, Session account) {
  if (!isPlainEmbyOriginal(uri, account.base)) return false;
  try {
    for (final pair in uri.query.split('&')) {
      final at = pair.indexOf('=');
      if (at < 0) continue;
      final name = Uri.decodeQueryComponent(
        pair.substring(0, at),
      ).toLowerCase();
      if (const {'api_key', 'x-emby-token'}.contains(name)) {
        final token = Uri.decodeQueryComponent(pair.substring(at + 1));
        if (token.isNotEmpty && token != account.token) return false;
      }
    }
    return true;
  } on FormatException {
    return false;
  }
}

String completeEmbyStreamAddress(
  String address,
  Uri base,
  Map<String, String> identity,
) {
  final uri = Uri.parse(address);
  if (uri.origin != base.origin ||
      !RegExp(
        r'/videos/[^/]+/(?:stream|original)(?:\.[^/]+)?$',
        caseSensitive: false,
      ).hasMatch(uri.path)) {
    return address;
  }
  final names = <String>{};
  final staticValues = <String>[];
  // Only decode names and the known Static flag, never opaque signature values.
  try {
    for (final pair in uri.query.split('&').where((pair) => pair.isNotEmpty)) {
      final separator = pair.indexOf('=');
      final name = Uri.decodeQueryComponent(
        separator < 0 ? pair : pair.substring(0, separator),
      ).toLowerCase();
      names.add(name);
      if (name == 'static') {
        staticValues.add(
          Uri.decodeQueryComponent(
            separator < 0 ? '' : pair.substring(separator + 1),
          ),
        );
      }
    }
  } on FormatException {
    return address;
  }
  // Signed or custom queries are server-owned. Only
  // complete the small, known unsigned Emby original-file route shape.
  if (staticValues.any((value) => value.toLowerCase() != 'true')) {
    throw const AppFailure('服务器返回了非原文件播放路线');
  }
  if (names.any((key) => !plainEmbyStreamParameters.contains(key))) {
    return address;
  }
  final extra = identity.entries
      .where((e) => !names.contains(e.key.toLowerCase()))
      .map(
        (e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
      )
      .join('&');
  if (extra.isEmpty) return address;
  final fragment = address.indexOf('#');
  final head = fragment < 0 ? address : address.substring(0, fragment);
  final tail = fragment < 0 ? '' : address.substring(fragment);
  final separator = head.endsWith('?') || head.endsWith('&')
      ? ''
      : head.contains('?')
      ? '&'
      : '?';
  return '$head$separator$extra$tail';
}

String mediaRouteFacts(String address, {String? accessToken}) {
  final uri = Uri.parse(address);
  final names = <String>{};
  var credential = false;
  bool? tokenMatches;
  for (final pair in uri.query.split('&')) {
    final parts = pair.split('=');
    try {
      final name = Uri.decodeQueryComponent(parts.first).toLowerCase();
      names.add(name);
      if (const {'api_key', 'x-emby-token'}.contains(name) &&
          parts.length > 1 &&
          parts[1].isNotEmpty) {
        credential = true;
        if (accessToken != null) {
          tokenMatches =
              (tokenMatches ?? true) &&
              Uri.decodeQueryComponent(parts.skip(1).join('=')) == accessToken;
        }
      }
    } on FormatException {
      names.add('unknown');
    }
  }
  final kind =
      RegExp(
        r'/videos/[^/]+/(?:stream|original)(?:\.[^/]+)?$',
        caseSensitive: false,
      ).hasMatch(uri.path)
      ? 'Emby 原文件入口'
      : '其他入口';
  return '$kind；地址认证=${credential ? '有' : '无'}；'
      '与登录身份一致=${tokenMatches == null
          ? '未知'
          : tokenMatches
          ? '是'
          : '否'}；'
      '地址内客户端身份=${const {'x-emby-client', 'x-emby-device-name', 'x-emby-device-id', 'x-emby-client-version'}.every(names.contains) ? '完整' : '不完整'}；'
      '缓存标记=${names.contains('tag') || names.contains('etag') ? '有' : '无'}；'
      '其他参数=${names.difference(plainEmbyStreamParameters).length} 项';
}

// Diagnostic values are fixed labels or comparisons only. Never emit an ID,
// query value, filename, host, account name, or a server-provided extension.
String mediaEntryCheckFacts(
  String address, {
  required Session account,
  required String sourceId,
  required String playSessionId,
}) {
  try {
    final uri = Uri.parse(address);
    final shape = RegExp(
      r'/(stream|original)(?:\.([a-z0-9]+))?$',
      caseSensitive: false,
    ).firstMatch(uri.path);
    const extensions = {
      'mkv',
      'mp4',
      'm4v',
      'avi',
      'webm',
      'mov',
      'ts',
      'm2ts',
      'iso',
      'wmv',
      'mpeg',
      'mpg',
    };
    final extension = shape?[2]?.toLowerCase();
    final suffix = extension == null
        ? '无扩展'
        : extensions.contains(extension)
        ? extension
        : '自定义扩展';
    final kind = shape == null ? '自定义' : shape[1]!.toLowerCase();
    final values = <String, List<String>>{};
    for (final pair in uri.query.split('&').where((pair) => pair.isNotEmpty)) {
      final at = pair.indexOf('=');
      final key = Uri.decodeQueryComponent(
        at < 0 ? pair : pair.substring(0, at),
      ).toLowerCase();
      if (!const {
        'static',
        'mediasourceid',
        'playsessionid',
        'deviceid',
        'x-emby-device-id',
      }.contains(key)) {
        continue;
      }
      (values[key] ??= []).add(
        Uri.decodeQueryComponent(at < 0 ? '' : pair.substring(at + 1)),
      );
    }
    String match(Iterable<String> keys, String expected) {
      final found = keys
          .expand((key) => values[key] ?? const <String>[])
          .toList();
      if (found.isEmpty) return '缺失';
      return found.every((value) => value == expected) ? '一致' : '不一致';
    }

    final static = values['static'];
    final original = static == null
        ? '缺失'
        : static.every((value) => value.toLowerCase() == 'true')
        ? 'true'
        : '非true或冲突';
    return '形态=$kind/$suffix；Static=$original；'
        '媒体源=${match(['mediasourceid'], sourceId)}；'
        '播放会话=${match(['playsessionid'], playSessionId)}；'
        '设备=${match(['deviceid', 'x-emby-device-id'], account.deviceId)}';
  } on FormatException {
    return '参数格式无法核对';
  }
}

class EmbyClient {
  EmbyClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 18),
    this.log,
    bool? liveEvents,
  }) : liveEvents = liveEvents ?? client == null,
       client = client ?? http.Client();
  final bool liveEvents;
  final http.Client client;
  final Duration timeout;
  final DiagnosticLog? log;
  final backgroundWork = BackgroundWork();
  final connection = ServerConnection();
  Future<void>? _connectionTest;
  Session? _session;
  // null means metadata has not been checked; empty means no server avatar.
  String? primaryImageTag;
  Session? get session => _session;
  set session(Session? value) {
    if (!identical(value, _session)) {
      connection.reset();
      primaryImageTag = null;
    }
    _session = value;
    log?.protect(_sessionSecrets);
  }

  List<String> get _sessionSecrets {
    final s = _session;
    return s == null
        ? []
        : [
            s.token,
            s.userId,
            s.username,
            s.deviceId,
            s.serverId,
            s.base.host,
          ].where((s) => s.length >= 3).toList();
  }

  void Function()? onUnauthorized;

  // Account candidates never change the live client's credentials, connection
  // status or optional-work scope. Only the transport is shared.
  EmbyClient forAccount([Session? account]) =>
      EmbyClient(client: _BorrowedTransport(client), timeout: timeout, log: log)
        ..session = account;

  void retireBrowsing() {
    onUnauthorized = null;
    backgroundWork.pause(this, true);
  }

  Uri endpoint(Uri base, String path, [Map<String, String>? query]) =>
      base.replace(path: '${base.path}/$path', queryParameters: query);
  Map<String, String> headers(
    String deviceId, {
    String? token,
    String? userId,
  }) {
    final safeId = deviceId.replaceAll('"', '').replaceAll('\\', '');
    if (safeId.codeUnits.any((c) => c < 32 || c > 126)) {
      throw const AppFailure('设备身份包含无效的 HTTP 字符');
    }
    final includeUser = token != null && userId != null && userId.isNotEmpty;
    if (includeUser &&
        (userId.contains(RegExp(r'["\\]')) ||
            userId.codeUnits.any((c) => c < 32 || c > 126))) {
      throw const AppFailure('用户身份包含无效的 HTTP 字符');
    }
    return {
      'X-Emby-Authorization':
          'Emby Client="Yingyu", Device="Android", DeviceId="$safeId", Version="$appVersion"'
          '${includeUser ? ', UserId="$userId"' : ''}',
      'X-Emby-Token': ?token,
      'Accept': 'application/json',
      'User-Agent': playbackUserAgent,
    };
  }

  Future<Json> request(
    Uri uri, {
    String method = 'GET',
    Json? body,
    required Map<String, String> headers,
    bool reportUnauthorized = true,
    List<String> diagnosticSecrets = const [],
    bool expectList = false,
    Duration? requestTimeout,
    bool updateServerOnFailure = true,
  }) async {
    final account = session;
    final ticket = connection.begin();
    final optional = BackgroundWork.current;
    final abort = Completer<void>();
    optional?.attach(abort);
    final limit = requestTimeout ?? timeout;
    void outcome(
      ServerStatus status, {
      String? detail,
      int? elapsed,
      bool authenticationFailure = false,
    }) {
      if (account == null ||
          session != account ||
          uri.origin != account.base.origin) {
        return;
      }
      // One media negotiation can fail while authenticated browsing still
      // works. Keep that error on the request, without declaring an outage.
      // A real 401 remains an account-wide authentication failure.
      if (!updateServerOnFailure &&
          status != ServerStatus.connected &&
          !authenticationFailure) {
        return;
      }
      connection.finish(ticket, status, reason: detail, elapsedMs: elapsed);
    }

    final operation = metadataOperation(uri);
    final requestId = log?.nextRequest('API') ?? 'API';
    final watch = Stopwatch()..start();
    final secrets = [..._sessionSecrets, ...diagnosticSecrets, uri.host];
    var stage = '发送请求';
    try {
      final req = http.AbortableRequest(method, uri, abortTrigger: abort.future)
        ..followRedirects = false;
      req.headers.addAll(headers);
      if (body != null) {
        req.headers['Content-Type'] = 'application/json';
        req.body = jsonEncode(body);
      }
      String? header(String key) => req.headers.entries
          .where((e) => e.key.toLowerCase() == key)
          .map((e) => e.value)
          .firstOrNull;
      log?.add(
        LogArea.api,
        '$requestId $operation：$method；${requestHeaderFacts(header)}；'
        '超时=${limit.inSeconds} 秒；自动跳转=关闭',
      );
      final res = await client.send(req).timeout(limit);
      log?.add(
        LogArea.api,
        '$requestId $operation：HTTP ${res.statusCode}；响应头耗时=${watch.elapsedMilliseconds} ms；'
        '${responseFacts((name) => res.headers[name], secrets: secrets)}',
        level: res.statusCode >= 400 ? LogLevel.error : LogLevel.info,
      );
      stage = '读取响应正文';
      if (res.statusCode >= 300 && res.statusCode < 400) {
        final location = res.headers['location'];
        final next = location == null ? null : Uri.tryParse(location);
        final sameOrigin =
            next != null &&
            (!next.hasScheme && !next.hasAuthority ||
                const {'http', 'https'}.contains(next.scheme) &&
                    next.origin == uri.origin);
        log?.add(
          LogArea.api,
          '$requestId 跳转目标=${next == null
              ? '未提供'
              : sameOrigin
              ? '同源'
              : '外部'}；未跟随',
        );
        await res.stream.listen((_) {}).cancel();
        outcome(ServerStatus.unavailable, detail: '接口发生重定向，请检查最终服务器地址');
        throw const AppFailure('服务器接口发生重定向，请在登录页填写最终服务器地址');
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final errorBody = await readDiagnosticBody(res.stream);
        recordHttpFailure(
          log,
          requestId,
          errorBody,
          secrets: secrets,
          area: LogArea.api,
        );
        outcome(
          res.statusCode == 401 || res.statusCode == 403
              ? ServerStatus.denied
              : res.statusCode >= 500 ||
                    res.statusCode == 408 ||
                    res.statusCode == 429
              ? ServerStatus.unavailable
              : ServerStatus.connected,
          authenticationFailure: res.statusCode == 401,
          detail:
              res.statusCode == 401 ||
                  res.statusCode == 403 ||
                  res.statusCode >= 500 ||
                  res.statusCode == 408 ||
                  res.statusCode == 429
              ? '服务器返回 HTTP ${res.statusCode}'
              : null,
        );
        if (res.statusCode == 401 &&
            reportUnauthorized &&
            identical(session, account)) {
          onUnauthorized?.call();
        }
        throw AppFailure(
          res.statusCode == 401
              ? '登录已过期，请重新登录'
              : res.statusCode == 403
              ? '服务器拒绝访问'
              : '服务器请求失败',
          status: res.statusCode,
        );
      }
      final bytes = await res.stream.toBytes().timeout(limit);
      if (optional != null && (optional.paused || abort.isCompleted)) {
        throw const BackgroundPaused();
      }
      log?.add(
        LogArea.api,
        '$requestId 正文接收完成：${bytes.length} 字节；总耗时=${watch.elapsedMilliseconds} ms',
      );
      if (bytes.isEmpty) {
        if (expectList) throw const AppFailure('服务器返回的数据格式不正确');
        outcome(ServerStatus.connected, elapsed: watch.elapsedMilliseconds);
        return {};
      }
      stage = '解析响应 JSON';
      final decoded = bytes.length > 256 * 1024
          ? await compute(_decodeMetadata, bytes)
          : _decodeMetadata(bytes);
      if (optional != null && (optional.paused || abort.isCompleted)) {
        throw const BackgroundPaused();
      }
      if (expectList) {
        if (decoded is! List || decoded.any((item) => item is! Map)) {
          throw const AppFailure('服务器返回的数据格式不正确');
        }
        outcome(ServerStatus.connected, elapsed: watch.elapsedMilliseconds);
        return {'Items': decoded, 'TotalRecordCount': decoded.length};
      }
      if (decoded is! Map) throw const AppFailure('服务器返回的数据格式不正确');
      outcome(ServerStatus.connected, elapsed: watch.elapsedMilliseconds);
      return object(decoded);
    } on http.RequestAbortedException {
      throw const BackgroundPaused();
    } on TimeoutException {
      outcome(ServerStatus.disconnected, detail: '连接超时，请检查网络与服务器');
      log?.add(
        LogArea.api,
        '$requestId $operation：阶段=$stage；TimeoutException；耗时=${watch.elapsedMilliseconds} ms',
        level: LogLevel.error,
      );
      throw AppFailure(
        updateServerOnFailure ? '连接超时，请检查网络后重试' : '$operation请求超时，尚未取得本次播放地址',
      );
    } on FormatException {
      outcome(ServerStatus.unavailable, detail: '服务器未返回有效的 Emby 数据');
      log?.add(
        LogArea.api,
        '$requestId $operation：阶段=$stage；FormatException；正文未导出',
        level: LogLevel.error,
      );
      throw AppFailure(
        updateServerOnFailure
            ? '服务器没有返回有效的 Emby 数据，请检查地址'
            : '$operation没有返回有效数据',
      );
    } on http.ClientException catch (error) {
      outcome(ServerStatus.disconnected, detail: '网络连接中断或服务器无法到达');
      log?.add(
        LogArea.api,
        '$requestId $operation：阶段=$stage；${redactLog(error.toString(), secrets: secrets)}；耗时=${watch.elapsedMilliseconds} ms',
        level: LogLevel.error,
      );
      throw AppFailure(
        updateServerOnFailure ? '网络连接失败，请检查服务器地址与网络' : '$operation请求未完成，网络连接异常',
      );
    } finally {
      optional?.detach(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  /// Same-origin, authenticated, read-only API check; no media/STRM request.
  Future<void> testConnection() => _connectionTest ??= backgroundWork
      .run(() async {
        final s = session;
        if (s == null) throw const AppFailure('请先登录 Emby');
        await request(
          endpoint(s.base, 'Users/${s.userId}'),
          headers: headers(s.deviceId, token: s.token, userId: s.userId),
          reportUnauthorized: false,
          requestTimeout: const Duration(seconds: 8),
        );
      })
      .whenComplete(() => _connectionTest = null);

  Future<Session> login(
    String address,
    String username,
    String password,
    String deviceId,
  ) async {
    final base = normalizeServer(address);
    final data = await request(
      endpoint(base, 'Users/AuthenticateByName'),
      method: 'POST',
      body: {'Username': username.trim(), 'Pw': password},
      headers: headers(deviceId),
      reportUnauthorized: false,
      diagnosticSecrets: [username.trim(), password, deviceId],
    );
    final user = object(data['User']);
    if ((data['AccessToken'] ?? '').toString().isEmpty ||
        (user['Id'] ?? '').toString().isEmpty) {
      throw const AppFailure('服务器未返回有效登录身份');
    }
    final signedIn = session = Session(
      base: base,
      userId: '${user['Id']}',
      token: '${data['AccessToken']}',
      username: user['Name']?.toString() ?? username.trim(),
      deviceId: deviceId,
      serverId: data['ServerId']?.toString() ?? '',
    );
    primaryImageTag = user['PrimaryImageTag']?.toString() ?? '';
    return signedIn;
  }

  Future<Json> api(
    String path, {
    Map<String, String>? query,
    String method = 'GET',
    Json? body,
    bool expectList = false,
    Duration? requestTimeout,
    bool updateServerOnFailure = true,
  }) {
    final s = session;
    if (s == null) throw const AppFailure('请先登录 Emby');
    return request(
      endpoint(s.base, path, query),
      method: method,
      body: body,
      headers: headers(s.deviceId, token: s.token, userId: s.userId),
      expectList: expectList,
      requestTimeout: requestTimeout,
      updateServerOnFailure: updateServerOnFailure,
    ).then((data) {
      for (final row in [data, ...objects(data['Items'])]) {
        SharedImageIdentity.remember(s, MediaItem(row));
      }
      return data;
    });
  }

  Future<void> validate() async {
    final owner = session!;
    final data = await api('Users/${owner.userId}');
    if (data['Id']?.toString() != owner.userId) {
      throw const AppFailure('服务器返回的账号身份不一致，未切换账号');
    }
    if (identical(session, owner)) {
      primaryImageTag = data['PrimaryImageTag']?.toString() ?? '';
    }
  }

  Future<void> logout() async {
    await api('Sessions/Logout', method: 'POST');
    session = null;
  }

  Future<List<MediaItem>> libraries() async =>
      ItemPage.fromJson(await api('Users/${session!.userId}/Views')).items;

  /// Changes only Emby's per-user resume visibility; never writes playback data.
  Future<Json> hideFromResume(String id) {
    if (id.isEmpty) throw const AppFailure('缺少影片编号，无法移出继续观看');
    return api(
      'Users/${session!.userId}/Items/$id/HideFromResume',
      method: 'POST',
      query: const {'Hide': 'true'},
    );
  }

  /// Dedicated personal-state endpoints never send a stale UserData snapshot.
  Future<Json> setFavorite(String id, bool value) => api(
    'Users/${session!.userId}/FavoriteItems/${Uri.encodeComponent(id)}',
    method: value ? 'POST' : 'DELETE',
  );

  Future<Json> setPersonalRating(String id, bool? likes) => api(
    'Users/${session!.userId}/Items/${Uri.encodeComponent(id)}/Rating',
    method: likes == null ? 'DELETE' : 'POST',
    query: likes == null ? null : {'Likes': '$likes'},
  );

  Future<Json> setPersonalPlayed(String id, bool played) => api(
    'Users/${session!.userId}/PlayedItems/${Uri.encodeComponent(id)}',
    method: played ? 'POST' : 'DELETE',
  );

  Future<ItemPage> personalItems(
    String filter, {
    int start = 0,
    int limit = 100,
    String? id,
  }) async {
    final data = await api(
      'Users/${session!.userId}/Items',
      query: {
        'Filters': filter,
        'Ids': ?id,
        'Recursive': 'true',
        'IncludeItemTypes': filter == 'IsPlayed' || filter == 'IsUnplayed'
            ? 'Movie,Episode,Video'
            : 'Movie,Series,Season,Episode,Video',
        'GroupItemsIntoCollections': 'false',
        'StartIndex': '$start',
        'Limit': '$limit',
        'EnableTotalRecordCount': 'true',
        'EnableUserData': 'true',
        'ImageTypeLimit': '1',
        'Fields':
            'ProviderIds,Overview,ProductionYear,RunTimeTicks,SeriesPrimaryImageTag',
        'SortBy': filter == 'IsPlayed' ? 'DatePlayed,SortName' : 'SortName',
        'SortOrder': filter == 'IsPlayed' ? 'Descending' : 'Ascending',
      },
    );
    if (data['Items'] is! List ||
        data['TotalRecordCount'] is! num ||
        integer(data['TotalRecordCount']) < objects(data['Items']).length) {
      throw const AppFailure('Emby 个人列表返回不完整，原有资料已保留');
    }
    final page = ItemPage.fromJson(data);
    if (filter == 'IsFavorite' &&
        page.items.any(
          (item) => object(item.data['UserData'])['IsFavorite'] != true,
        )) {
      throw const AppFailure('Emby 未正确返回收藏筛选，原有收藏已保留');
    }
    return page;
  }

  /// Homepage queries mirror the read-only PC 0.6.5 presentation contract.
  /// Preserve server order; never open media or invent local "latest" sorting.
  Future<ItemPage> resumeItems({
    int start = 0,
    int limit = 18,
  }) async => ItemPage.fromJson(
    await api(
      'Users/${session!.userId}/Items/Resume',
      query: {
        'Limit': '$limit',
        if (start > 0) 'StartIndex': '$start',
        'EnableTotalRecordCount': 'true',
        'MediaTypes': 'Video',
        'Fields':
            'ProviderIds,Overview,PrimaryImageAspectRatio,SeriesPrimaryImageTag,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,Genres,OfficialRating,ProductionYear,RunTimeTicks,CommunityRating',
        'EnableUserData': 'true',
        'EnableImageTypes': 'Primary,Thumb,Backdrop',
        'ImageTypeLimit': '1',
      },
    ),
  );
  Future<List<MediaItem>> latestItems(
    String parentId,
  ) async => ItemPage.fromJson(
    await api(
      'Users/${session!.userId}/Items/Latest',
      expectList: true,
      query: {
        'Limit': '18',
        'ParentId': parentId,
        'IncludeItemTypes': 'Movie,Episode',
        'Fields':
            'ProviderIds,Overview,PrimaryImageAspectRatio,DateCreated,SeriesPrimaryImageTag,Genres,OfficialRating,ProductionYear,RunTimeTicks,CommunityRating,RecursiveItemCount',
        'EnableUserData': 'true',
        'ImageTypeLimit': '1',
      },
    ),
  ).items;

  Future<MediaItem> prepareEpisodeMetadata(String id) async => MediaItem(
    await api(
      'Users/${session!.userId}/Items/$id',
      requestTimeout: const Duration(seconds: 3),
      updateServerOnFailure: false,
    ),
  );

  Future<ItemPage> people(String term, {int start = 0}) async =>
      ItemPage.fromJson(
        await api(
          'Persons',
          query: {
            'UserId': session!.userId,
            'SearchTerm': term,
            'Fields': 'ProviderIds',
            'StartIndex': '$start',
            'Limit': '48',
            'EnableImages': 'true',
            'EnableTotalRecordCount': 'true',
          },
        ),
      );

  Future<ItemPage> personItems({
    String? id,
    String? name,
    int start = 0,
  }) async => ItemPage.fromJson(
    await api(
      'Users/${session!.userId}/Items',
      query: {
        if (id != null && id.isNotEmpty)
          'PersonIds': id
        else if (name != null && name.isNotEmpty)
          'Person': name,
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie,Series',
        'StartIndex': '$start',
        'Limit': '48',
        'EnableUserData': 'true',
        'Fields': 'Overview,ProductionYear,CommunityRating',
        'EnableTotalRecordCount': 'true',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
      },
    ),
  );

  Future<List<Json>> searchSubtitles(
    String id,
    String language,
    String? source,
  ) async => objects(
    (await api(
      'Items/${Uri.encodeComponent(id)}/RemoteSearch/Subtitles/${Uri.encodeComponent(language)}',
      expectList: true,
      query: {'MediaSourceId': ?source},
    ))['Items'],
  );

  Future<Json> downloadSubtitle(
    String id,
    String subtitle,
    String? source,
  ) => api(
    'Items/${Uri.encodeComponent(id)}/RemoteSearch/Subtitles/${Uri.encodeComponent(subtitle)}',
    method: 'POST',
    query: {'MediaSourceId': ?source},
  );

  /// Fetch a selected provider result as a temporary subtitle, without adding
  /// a file to the server or changing the current video playback route.
  PlaybackRoute remoteSubtitleRoute(String subtitle) {
    final account = session;
    if (account == null || subtitle.isEmpty) {
      throw const AppFailure('请先登录后选择字幕');
    }
    return PlaybackRoute(
      url: endpoint(
        account.base,
        'Providers/Subtitles/Subtitles/${Uri.encodeComponent(subtitle)}',
        null,
      ).toString(),
      sourceId: '',
      sessionId: '',
      headers: const {},
      streams: const [],
      serverBase: account.base,
      sameOriginHeaders: headers(
        account.deviceId,
        token: account.token,
        userId: account.userId,
      ),
    );
  }

  Future<ItemPage> items({
    String? parent,
    String search = '',
    int start = 0,
    bool recursive = true,
  }) async => ItemPage.fromJson(
    await api(
      'Users/${session!.userId}/Items',
      query: {
        'ParentId': ?parent,
        if (search.isNotEmpty) 'SearchTerm': search,
        'StartIndex': '$start',
        'Limit': '48',
        'Recursive': '$recursive',
        if (recursive) 'IncludeItemTypes': 'Movie,Series',
        'Fields': 'ProviderIds,Overview,PrimaryImageAspectRatio,MediaSources',
        'EnableUserData': 'true',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
        'EnableTotalRecordCount': 'true',
      },
    ),
  );

  /// Flat title catalogue for browsing. Server collection grouping is disabled
  /// explicitly; series still open the existing season/episode detail page.
  Future<ItemPage> browseItems({
    String? parent,
    String search = '',
    int start = 0,
    int? limit = 48,
    String sort = '',
    bool? played,
    bool minimal = false,
    bool resourceSnapshot = false,
  }) async => ItemPage.fromJson(
    await api(
      'Users/${session!.userId}/Items',
      query: {
        'ParentId': ?parent,
        if (search.isNotEmpty) 'SearchTerm': search,
        'StartIndex': '$start',
        if (limit != null) 'Limit': '$limit',
        'Recursive': 'true',
        'IncludeItemTypes': resourceSnapshot
            ? 'Movie,Series,Video,Season,Episode'
            : 'Movie,Series,Video',
        'GroupItemsIntoCollections': 'false',
        'Fields': minimal
            ? 'ProviderIds,SortName,DateCreated,Genres,RecursiveItemCount,ProductionYear,PremiereDate,CommunityRating'
            : 'ProviderIds,Overview,SortName,DateCreated,Genres,RecursiveItemCount,ProductionYear,PremiereDate,CommunityRating',
        'EnableUserData': 'true',
        'EnableTotalRecordCount': 'true',
        'ImageTypeLimit': '1',
        if (sort.isNotEmpty) 'SortBy': sort,
        if (sort.isNotEmpty)
          'SortOrder': sort == 'SortName' ? 'Ascending' : 'Descending',
        if (played != null) 'IsPlayed': '$played',
      },
    ),
  );

  Future<MediaItem> detail(String id, {Duration? requestTimeout}) async {
    final item = MediaItem(
      await api(
        'Users/${session!.userId}/Items/$id',
        requestTimeout: requestTimeout,
      ),
    );
    log?.add(
      LogArea.api,
      '演职员资料：字段存在=${item.data["People"] is List}；人数=${objects(item.data["People"]).length}',
    );
    log?.add(
      LogArea.progress,
      '服务器进度读取：位置=${item.resume.inMilliseconds} ms；资料时长=${item.duration.inMilliseconds} ms；已看=${object(item.data["UserData"])["Played"] == true}',
    );
    return item;
  }

  Future<List<MediaItem>> progressItems(List<String> ids) async =>
      ItemPage.fromJson(
        await api(
          'Users/${session!.userId}/Items',
          query: {
            'Ids': ids.join(','),
            'Limit': '${ids.length}',
            'EnableUserData': 'true',
          },
        ),
      ).items;

  /// A complete, unfiltered ID lookup. Partial/malformed replies cannot prove
  /// deletion and must never be used to evict cached metadata.
  Future<Set<String>> existingItemIds(
    List<String> ids, {
    bool direct = false,
  }) async {
    if (ids.isEmpty) return {};
    final data = await api(
      direct ? 'Items' : 'Users/${session!.userId}/Items',
      query: {
        if (direct) 'UserId': session!.userId,
        'Ids': ids.join(','),
        'Limit': '${ids.length}',
        if (!direct) 'Recursive': 'true',
        'EnableTotalRecordCount': 'true',
        'EnableImages': 'false',
        'EnableUserData': 'false',
        'GroupItemsIntoCollections': 'false',
      },
    );
    return _checkedItemIds(data, ids);
  }

  Set<String> _checkedItemIds(Json data, List<String> ids) {
    if (data['Items'] is! List || data['TotalRecordCount'] is! num) {
      throw const AppFailure('资源核对返回不完整，原缓存已保留');
    }
    final items = objects(data['Items']);
    final found = items.map((item) => item['Id']?.toString() ?? '').toSet();
    if (data['TotalRecordCount'] != items.length ||
        (data['Items'] as List).length != items.length ||
        found.length != items.length ||
        found.contains('') ||
        found.any((id) => !ids.contains(id))) {
      throw const AppFailure('资源核对返回不完整，原缓存已保留');
    }
    return found;
  }

  /// A list omission alone is not deletion: some servers omit grouped or
  /// virtual entries from ID queries. Confirm against the individual resource.
  Future<bool> itemExists(String id) async {
    try {
      final data = await api(
        'Users/${session!.userId}/Items/${Uri.encodeComponent(id)}',
      );
      if (data['Id']?.toString() != id) {
        throw const AppFailure('资源核对返回不完整，原缓存已保留');
      }
      return true;
    } on AppFailure catch (error) {
      if (error.status == 404 || error.status == 410) return false;
      rethrow;
    }
  }

  Future<ItemPage> seasons(String id) async => ItemPage.fromJson(
    await api(
      'Shows/$id/Seasons',
      query: {'UserId': session!.userId, 'Fields': 'Overview'},
    ),
  );

  /// Display focus only: latest watched episode, including completed episodes.
  /// Do not request PlaybackInfo or open a media/STRM endpoint here.
  Future<MediaItem?> lastWatchedEpisode(String seriesId) async {
    final page = ItemPage.fromJson(
      await api(
        'Users/${session!.userId}/Items',
        query: {
          'ParentId': seriesId,
          'Recursive': 'true',
          'IncludeItemTypes': 'Episode',
          'SortBy': 'DatePlayed',
          'SortOrder': 'Descending',
          'Limit': '1',
          'EnableUserData': 'true',
          'Fields': 'ParentId',
          'ImageTypeLimit': '1',
        },
      ),
    );
    final entry = page.items.firstOrNull;
    if (entry == null ||
        entry.type != 'Episode' ||
        entry.data['SeriesId']?.toString() != seriesId) {
      return null;
    }
    final data = object(entry.data['UserData']);
    return entry.resume > Duration.zero ||
            data['Played'] == true ||
            integer(data['PlayCount']) > 0 ||
            DateTime.tryParse(data['LastPlayedDate']?.toString() ?? '') != null
        ? entry
        : null;
  }

  /// One bounded metadata read for the homepage, never one request per card.
  /// No PlaybackInfo, source URL, or media body is requested here.
  Future<List<MediaItem>> recentWatchedEpisodes() async {
    final page = ItemPage.fromJson(
      await api(
        'Users/${session!.userId}/Items',
        query: {
          'Recursive': 'true',
          'IncludeItemTypes': 'Episode',
          'Filters': 'IsResumable',
          'SortBy': 'DatePlayed',
          'SortOrder': 'Descending',
          'Limit': '96',
          'EnableUserData': 'true',
          'Fields': 'ParentId',
          'ImageTypeLimit': '1',
        },
      ),
    );
    return page.items
        .take(96)
        .where(
          (item) =>
              item.type == 'Episode' &&
              item.id.isNotEmpty &&
              '${item.data['SeriesId'] ?? ''}'.isNotEmpty,
        )
        .toList();
  }

  Future<ItemPage> episodes(
    String seriesId,
    String seasonId, {
    int start = 0,
  }) async => ItemPage.fromJson(
    await api(
      'Shows/$seriesId/Episodes',
      query: {
        'UserId': session!.userId,
        'SeasonId': seasonId,
        'StartIndex': '$start',
        'Limit': '48',
        'Fields': 'ProviderIds,Overview,MediaSources',
      },
    ),
  );
  Future<ItemPage> episodeWindow(
    String seriesId,
    String seasonId,
    String fromId,
  ) async => ItemPage.fromJson(
    await api(
      'Shows/$seriesId/Episodes',
      query: {
        'UserId': session!.userId,
        'SeasonId': seasonId,
        'StartItemId': fromId,
        'Limit': '48',
        'Fields': 'ProviderIds,Overview,MediaSources',
      },
    ),
  );

  /// Display-only complete season in server episode order. Omitting Limit does
  /// not imply downloading any image or opening a media source.
  Future<ItemPage> episodeCatalogue(
    String seriesId,
    String seasonId, {
    bool Function()? allowed,
    Duration spacing = const Duration(milliseconds: 350),
  }) async {
    final items = <MediaItem>[], ids = <String>{};
    var start = 0;
    int? expectedTotal;
    while (true) {
      if (allowed?.call() == false) throw const AppFailure('剧集请求已暂停');
      final page = ItemPage.fromJson(
        await api(
          'Shows/$seriesId/Episodes',
          query: {
            'UserId': session!.userId,
            'SeasonId': seasonId,
            'StartIndex': '$start',
            'EnableUserData': 'true',
            'Fields': 'SeriesPrimaryImage',
          },
        ),
      );
      if (allowed?.call() == false) throw const AppFailure('剧集请求已暂停');
      final added = page.items.where((item) => ids.add(item.id)).toList();
      expectedTotal ??= page.total;
      if (!page.countKnown ||
          page.total != expectedTotal ||
          added.length != page.items.length ||
          page.items.any((item) => item.id.isEmpty || item.type != 'Episode') ||
          start + page.items.length > page.total) {
        throw const AppFailure('分集目录返回不完整，原记录已保留');
      }
      items.addAll(added);
      start += page.items.length;
      if (page.total <= start) break;
      if (added.isEmpty) throw const AppFailure('剧集资料返回不完整，请重试');
      await Future<void>.delayed(spacing);
    }
    return ItemPage(items, items.length);
  }

  String imageUrl(
    MediaItem item, {
    bool backdrop = false,
    bool thumbnail = false,
  }) => SharedImageIdentity.register(
    session!,
    item,
    endpoint(
      session!.base,
      'Items/${item.id}/Images/${thumbnail
          ? 'Thumb'
          : backdrop
          ? 'Backdrop/0'
          : 'Primary'}',
      {
        'api_key': session!.token,
        'maxWidth': thumbnail
            ? '640'
            : backdrop
            ? '1280'
            : '360',
        'quality': '85',
        'tag': thumbnail
            ? '${object(item.data['ImageTags'])['Thumb'] ?? ''}'
            : backdrop
            ? item.backdropTag
            : item.imageTag,
      },
    ).toString(),
    backdrop: backdrop,
    thumbnail: thumbnail,
  );

  /// Only call with a freshly fetched user detail, never a cached library row.
  /// Emby documents static streaming without PlaybackInfo: the client supplies
  /// a new PlaySessionId. Incomplete/live routes retain negotiation.
  Future<PlaybackRoute> preparePlayback(
    MediaItem detail, {
    String? sourceId,
    Duration start = Duration.zero,
  }) async {
    final sources = objects(detail.data['MediaSources']);
    final source = sourceId == null
        ? sources.firstOrNull
        : sources.where((s) => s['Id'] == sourceId).firstOrNull;
    final path = source?['Path']?.toString() ?? '';
    final direct = source?['DirectStreamUrl']?.toString() ?? '';
    bool freshDirectIdentity(Uri uri) =>
        !uri.queryParametersAll.keys.any(
          (key) => key.toLowerCase() == 'playsessionid',
        ) &&
        uri.queryParametersAll.entries
            .where((entry) => entry.key.toLowerCase() == 'mediasourceid')
            .every(
              (entry) => entry.value.every(
                (value) => value == source?['Id']?.toString(),
              ),
            ) &&
        uri.queryParametersAll.entries
            .where((entry) => entry.key.toLowerCase() == 'static')
            .every(
              (entry) =>
                  entry.value.every((value) => value.toLowerCase() == 'true'),
            );
    bool plainOriginalEntry() {
      if (direct.isEmpty) return true;
      try {
        final uri = Uri.parse(resolveMediaAddress(session!.base, direct));
        return canUseAccountHeaders(uri, session!) &&
            RegExp(
              r'/videos/[^/]+/stream(?:\.[a-z0-9]+)?$',
              caseSensitive: false,
            ).hasMatch(uri.path) &&
            freshDirectIdentity(uri);
      } on FormatException {
        return false;
      } on AppFailure {
        return false;
      }
    }

    final completeSource =
        detail.playable &&
        source != null &&
        (source['Id']?.toString().isNotEmpty ?? false) &&
        source['Type'] == 'Default' &&
        source['SupportsDirectStream'] == true &&
        source['RequiresOpening'] != true &&
        source['RequiresClosing'] != true &&
        source['IsInfiniteStream'] != true &&
        source['LiveStreamId'] == null &&
        source['OpenToken'] == null &&
        source['RequiredHttpHeaders'] is Map &&
        source['MediaStreams'] is List &&
        // Do not lose server-generated per-user track defaults for known tracks.
        ((source['MediaStreams'] as List).isEmpty ||
            (source.containsKey('DefaultAudioStreamIndex') &&
                source.containsKey('DefaultSubtitleStreamIndex')));
    final canStream =
        completeSource &&
        source['Protocol']?.toString().toLowerCase() == 'file' &&
        source['Container']?.toString().toLowerCase() != 'strm' &&
        !path.toLowerCase().endsWith('.strm') &&
        source['IsRemote'] != true &&
        !const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme) &&
        plainOriginalEntry() &&
        path.isNotEmpty;
    // The static endpoint is an Emby client entry even when Path is a remote
    // server input. A complete default source explicitly allowing direct
    // streaming does not need a blocking PlaybackInfo request. Never open Path.
    final completeOriginal =
        completeSource &&
        direct.isEmpty &&
        path.isNotEmpty &&
        const {
          'file',
          'http',
          'https',
        }.contains(source['Protocol']?.toString().toLowerCase());
    if (canStream || completeOriginal) {
      log?.add(
        LogArea.route,
        '开播准备：使用本次详情中的完整静态媒体源与 Emby 原文件入口，省去重复播放信息请求；客户端生成播放会话，不直连原始 Path',
      );
      return _playbackRoute(
        detail,
        {
          'PlaySessionId': newId(),
          'MediaSources': [source],
        },
        sourceId: sourceId,
        originalEntry: true,
      );
    }
    var usableDirect = false;
    if (completeSource && direct.isNotEmpty) {
      try {
        final uri = Uri.parse(resolveMediaAddress(session!.base, direct));
        usableDirect =
            const {'http', 'https'}.contains(uri.scheme) &&
            // A fixed session requires negotiation; do not pair its URL with
            // a new client session. A supplied source ID must match selection.
            freshDirectIdentity(uri);
      } on FormatException {
        // Invalid entries still need one server negotiation, never a probe.
      } on AppFailure {
        // Only a server-provided HTTP(S) DirectStreamUrl can use this path.
      }
    }
    if (usableDirect) {
      log?.add(LogArea.route, '开播准备：复用本次详情中的明确原画入口、请求头和轨道默认值，省去重复播放信息请求');
      return _playbackRoute(detail, {
        'PlaySessionId': newId(),
        'MediaSources': [source],
      }, sourceId: sourceId);
    }
    log?.add(
      LogArea.route,
      '开播准备：取得一次播放信息；完整媒体源=${completeSource ? '是' : '否'}；'
      '明确播放地址=${direct.isNotEmpty ? '有' : '无'}；'
      'HTTP Path=${const {'http', 'https'}.contains(Uri.tryParse(path)?.scheme) ? '有' : '无'}；'
      '不预探测媒体',
    );
    return playback(detail, sourceId: sourceId, start: start);
  }

  Future<PlaybackRoute> playback(
    MediaItem item, {
    String? sourceId,
    Duration start = Duration.zero,
  }) async {
    log?.protect([
      item.id,
      item.title,
      item.data['SeriesName']?.toString() ?? '',
    ]);
    final data = await api(
      'Items/${item.id}/PlaybackInfo',
      method: 'POST',
      updateServerOnFailure: false,
      body: {
        'UserId': session!.userId,
        'StartTimeTicks': ticks(start),
        'IsPlayback': true,
        'AutoOpenLiveStream': false,
        'EnableDirectPlay': true,
        'EnableDirectStream': true,
        'EnableTranscoding': false,
        'AllowVideoStreamCopy': true,
        'AllowAudioStreamCopy': true,
        'MediaSourceId': ?sourceId,
        'DeviceProfile': {
          'Name': 'Yingyu MPV',
          'MaxStreamingBitrate': 2147483647,
          'DirectPlayProfiles': [
            {'Type': 'Video'},
            {'Type': 'Audio'},
          ],
          'TranscodingProfiles': <Object>[],
        },
      },
    );
    return _playbackRoute(item, data, sourceId: sourceId);
  }

  PlaybackRoute _playbackRoute(
    MediaItem item,
    Json data, {
    String? sourceId,
    bool originalEntry = false,
  }) {
    log?.protect([
      item.id,
      item.title,
      item.data['SeriesName']?.toString() ?? '',
    ]);
    if (data['ErrorCode'] != null && data['ErrorCode'] != '') {
      throw AppFailure('服务器无法提供原文件：${data['ErrorCode']}');
    }
    final sources = objects(data['MediaSources']);
    if (sources.isEmpty) throw const AppFailure('没有可播放的媒体源');
    final selected = sourceId == null
        ? sources.first
        : sources.firstWhere(
            (s) => s['Id'] == sourceId,
            orElse: () => throw const AppFailure('所选媒体源已失效'),
          );
    if (selected['RequiresOpening'] == true ||
        selected['Type'] == 'LiveStream') {
      throw const AppFailure('当前首版尚不支持需要另行打开的直播源');
    }
    final id = selected['Id']?.toString() ?? '';
    if (id.isEmpty) throw const AppFailure('媒体源缺少身份信息');
    final playId = data['PlaySessionId']?.toString() ?? newId();
    final s = session!;
    final identity = {
      'api_key': s.token,
      'Static': 'true',
      'MediaSourceId': id,
      'PlaySessionId': playId,
      'DeviceId': s.deviceId,
    };
    final container = selected['Container']?.toString() ?? '';
    final extension =
        RegExp(r'^[a-zA-Z0-9]+$').hasMatch(container) &&
            container.toLowerCase() != 'strm'
        ? '.$container'
        : '';
    final canonical = endpoint(
      s.base,
      'Videos/${item.id}/stream$extension',
      {...identity}
        ..remove('Static')
        ..['static'] = 'true',
    ).toString();
    // Keep the known original container on the documented static endpoint.
    // Extension-aware reverse proxies can match it immediately instead of
    // waiting for an upstream compatibility fallback. Unknown/STRM stays bare.
    var url = endpoint(
      s.base,
      'Videos/${item.id}/stream$extension',
      identity,
    ).toString();
    // Only explicit HTTP media URLs are eligible. Never use TranscodingUrl.
    // A detail Path describes the server's source, not verified client access.
    // Static playback goes straight to the authenticated entry. Do not spend a
    // timeout probing a second candidate before the one required STRM resolve.
    final direct = originalEntry
        ? ''
        : selected['DirectStreamUrl']?.toString() ?? '';
    final path = selected['Path']?.toString() ?? '';
    final pathScheme = Uri.tryParse(path)?.scheme;
    final httpPath = pathScheme == 'http' || pathScheme == 'https';
    final raw = originalEntry
        ? ''
        : direct.isNotEmpty
        ? direct
        : (pathScheme == 'http' ||
              pathScheme == 'https' ||
              selected['Protocol']?.toString().toLowerCase() == 'http')
        ? path
        : '';
    if (raw.isNotEmpty) {
      log?.add(
        LogArea.route,
        '服务器提供：${mediaRouteFacts(resolveMediaAddress(s.base, raw), accessToken: s.token)}',
      );
      url = completeEmbyStreamAddress(
        resolveMediaAddress(s.base, raw),
        s.base,
        identity,
      );
    }
    log?.add(
      LogArea.route,
      '交给播放器：${mediaRouteFacts(url, accessToken: s.token)}；'
      '另有 HTTP Path=${httpPath ? '是' : '否'}；'
      '服务器允许直播放=${selected['SupportsDirectPlay'] == true
          ? '是'
          : selected['SupportsDirectPlay'] == false
          ? '否'
          : '未声明'}',
    );
    log?.add(
      LogArea.route,
      '入口参数核对：${mediaEntryCheckFacts(url, account: s, sourceId: id, playSessionId: playId)}',
    );
    final mediaHeaders = <String, String>{};
    for (final e in object(selected['RequiredHttpHeaders']).entries) {
      final value = e.value?.toString() ?? '';
      if (!RegExp(r'^[!#$%&\x27*+.^_`|~0-9A-Za-z-]+$').hasMatch(e.key) ||
          value.contains(RegExp(r'[\r\n]'))) {
        throw const AppFailure('媒体源包含无效请求头');
      }
      if ([
        'x-emby-token',
        'x-emby-authorization',
      ].contains(e.key.toLowerCase())) {
        continue;
      }
      mediaHeaders[e.key] = value;
    }
    if (!mediaHeaders.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      mediaHeaders['User-Agent'] = playbackUserAgent;
    }
    final target = Uri.parse(url);
    final querySecrets = <String>[];
    try {
      querySecrets.addAll(
        target.queryParametersAll.values.expand((values) => values),
      );
    } on FormatException {
      // Diagnostics must not reject an otherwise opaque signed media query.
    }
    final protected =
        [
              ..._sessionSecrets,
              item.id,
              item.title,
              item.data['SeriesName']?.toString() ?? '',
              id,
              playId,
              target.host,
              ...querySecrets,
            ]
            .where(
              (value) =>
                  value.length >= 3 && value != 'true' && value != 'false',
            )
            .toList();
    log?.protect(protected);
    log?.add(
      LogArea.route,
      '路线来源=${direct.isNotEmpty
          ? 'DirectStreamUrl'
          : raw.isNotEmpty
          ? 'HTTP Path'
          : 'Emby 原文件接口'}；'
      '目标=${target.origin == s.base.origin ? 'Emby 同源' : '外部媒体服务'}；'
      '服务指定请求头=${mediaHeaders.length - (object(selected['RequiredHttpHeaders']).isEmpty ? 1 : 0)} 项；'
      '使用原文件播放',
    );
    return PlaybackRoute(
      url: url,
      sourceId: id,
      sessionId: playId,
      headers: mediaHeaders,
      streams: objects(selected['MediaStreams']),
      defaultAudioIndex: selected['DefaultAudioStreamIndex'] is num
          ? integer(selected['DefaultAudioStreamIndex'])
          : null,
      defaultSubtitleIndex: selected['DefaultSubtitleStreamIndex'] is num
          ? integer(selected['DefaultSubtitleStreamIndex'])
          : null,
      discKind: discSourceKind(selected),
      discFolderUrl:
          httpPath && discSourceKind(selected) == DiscKind.blurayFolder
          ? path
          : null,
      diagnosticSecrets: protected,
      serverBase: s.base,
      sameOriginHeaders: canUseAccountHeaders(target, s)
          ? Map.fromEntries(
              headers(
                s.deviceId,
                token: s.token,
                userId: s.userId,
              ).entries.where((e) => e.key.toLowerCase().startsWith('x-emby-')),
            )
          : const {},
      diagnosticCanonicalUrl: isPlainEmbyOriginal(target, s.base)
          ? canonical
          : null,
      playMethod:
          direct.isEmpty && raw.isNotEmpty && target.origin != s.base.origin
          ? 'DirectPlay'
          : 'DirectStream',
    );
  }

  Future<void> report(
    String event,
    MediaItem item,
    PlaybackRoute route,
    Duration position,
    bool paused, {
    Duration? duration,
    double rate = 1,
    String eventName = 'TimeUpdate',
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    log?.add(
      LogArea.progress,
      '进度发送：阶段=${event.isEmpty ? "Started" : event}；事件=$eventName；位置=${position.inMilliseconds} ms；真实时长=${duration?.inMilliseconds ?? 0} ms；倍速=$rate；暂停=$paused；播放会话=${route.sessionId.isNotEmpty}；媒体源=${route.sourceId.isNotEmpty}；方式=${route.playMethod}',
    );
    await api(
      'Sessions/Playing${event.isEmpty ? '' : '/$event'}',
      method: 'POST',
      body: {
        'ItemId': item.id,
        'MediaSourceId': route.sourceId,
        'PlaySessionId': route.sessionId,
        'PositionTicks': ticks(position),
        'AudioStreamIndex': ?audioStreamIndex,
        'SubtitleStreamIndex': ?subtitleStreamIndex,
        if (duration != null && duration > Duration.zero)
          'RunTimeTicks': ticks(duration),
        'PlaybackRate': rate,
        if (event == 'Progress') 'EventName': eventName,
        'IsPaused': paused,
        'CanSeek': true,
        'PlayMethod': route.playMethod,
        'RepeatMode': 'RepeatNone',
      },
    );
    log?.add(
      LogArea.progress,
      '进度接口已接受：阶段=${event.isEmpty ? "Started" : event}；位置=${position.inMilliseconds} ms',
    );
  }

  /// Repair a verified mismatch for stopped playback or a durable checkpoint. Preserve the existing
  /// favorite/play-count/played fields; never change server resume settings.
  Future<void> saveResume(
    MediaItem saved,
    Duration position, {
    Duration? requestTimeout,
  }) async {
    final user = object(saved.data['UserData']);
    if (saved.id.isEmpty ||
        !const [
          'PlaybackPositionTicks',
          'Played',
          'PlayCount',
          'IsFavorite',
        ].every(user.containsKey)) {
      throw const AppFailure('服务器未提供完整用户进度，无法安全补存');
    }
    await api(
      'Users/${session!.userId}/Items/${saved.id}/UserData',
      method: 'POST',
      requestTimeout: requestTimeout,
      body: {
        for (final name in const [
          'Rating',
          'PlayedPercentage',
          'UnplayedItemCount',
          'PlayCount',
          'IsFavorite',
          'LastPlayedDate',
          'Played',
          'Key',
        ])
          if (user.containsKey(name)) name: user[name],
        'PlaybackPositionTicks': ticks(position),
      },
    );
    log?.add(
      LogArea.progress,
      '用户进度补存接口已接受；位置=${position.inMilliseconds} ms；等待回读确认',
    );
  }

  Future<void> markCompleted(String id, DateTime watchedAt) async {
    if (id.isEmpty) throw const AppFailure('缺少影片编号，无法同步已看记录');
    await api(
      'Users/${session!.userId}/PlayedItems/${Uri.encodeComponent(id)}',
      method: 'POST',
      query: {'DatePlayed': watchedAt.toUtc().toIso8601String()},
      requestTimeout: const Duration(seconds: 3),
    );
  }

  void close() => client.close();
}

class _BorrowedTransport extends http.BaseClient {
  _BorrowedTransport(this.owner);
  final http.Client owner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      owner.send(request);
  @override
  void close() {}
}
