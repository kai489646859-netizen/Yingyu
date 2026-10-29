import '../core/log.dart';

/// Translates FFmpeg's request/header events into bounded, non-sensitive facts.
/// Raw header values and paths never leave this in-memory parser.
class HttpPlaybackTrace {
  // Startup parser budget is independent of the retained history capacity.
  static const eventLimit = 600;
  HttpPlaybackTrace({
    required this.log,
    required String address,
    required this.headers,
    this.serverBase,
    this.phase = '开播',
  }) : initial = Uri.parse(address),
       _initialTarget = requestTarget(address),
       _expectedTarget = requestTarget(address);
  final DiagnosticLog log;
  final String phase;
  final Uri initial;
  final String _initialTarget;
  final Uri? serverBase;
  final Map<String, String> headers;
  int requests = 0;
  String? _expectedTarget;
  String? _target, _method, _host, _agent;
  bool _cookie = false, _referer = false, _range = false, _emby = false;
  String _lastDestination = '未知目标';
  int _events = 0;
  bool _finished = false;
  final _watch = Stopwatch()..start();
  int _requestStarted = 0;
  late final _traceId = log.nextRequest('MPV');

  static String requestTarget(String address) {
    final value = address
        .replaceFirst(RegExp(r'^https?://[^/?#]+', caseSensitive: false), '')
        .split('#')
        .first;
    return value.isEmpty
        ? '/'
        : value.startsWith('?')
        ? '/$value'
        : value;
  }

  String destination(String? authority) {
    if (authority == null) return '未知目标';
    bool matches(Uri uri) =>
        authority.toLowerCase() == uri.authority.toLowerCase() ||
        authority.toLowerCase() == '${uri.host}:${uri.port}'.toLowerCase();
    if (serverBase != null && matches(serverBase!)) return 'Emby 同源';
    if (matches(initial)) return '初始媒体服务';
    return '跳转后的媒体服务';
  }

  void record(String message, {LogLevel level = LogLevel.info}) {
    if (_finished || ++_events > eventLimit) return;
    log.add(LogArea.network, '$_traceId [$phase] $message', level: level);
  }

  void flushRequest() {
    if (_method == null) return;
    _lastDestination = destination(_host);
    final expectedAgent = headers.entries
        .where((e) => e.key.toLowerCase() == 'user-agent')
        .map((e) => e.value)
        .firstOrNull;
    // MPV can return to its original URL for a Range request after a redirect.
    // Compare against that original target, not the preceding external URL.
    final initialRequest =
        _host?.toLowerCase() == initial.authority.toLowerCase() ||
        _host?.toLowerCase() == '${initial.host}:${initial.port}'.toLowerCase();
    final expectedTarget = initialRequest ? _initialTarget : _expectedTarget;
    record(
      '请求 #$requests：$_method；目标=$_lastDestination；'
      '地址原样=${expectedTarget == null
          ? '未知'
          : _target == expectedTarget
          ? '是'
          : '否'}；'
      'UA=${_agent == null
          ? '未观察到'
          : _agent == expectedAgent
          ? '一致'
          : '不一致'}；'
      '范围请求=${_range ? '有' : '无'}；媒体凭据=${_cookie ? '有' : '无'}；'
      '来源头=${_referer ? '有' : '无'}；Emby 认证头=${_emby ? '有' : '无'}',
    );
    _method = null;
  }

  void add(String prefix, String text) {
    if (_finished ||
        _events >= eventLimit ||
        !RegExp(r'^ffmpeg(/|$)').hasMatch(prefix)) {
      return;
    }
    for (var line in text.split('\n')) {
      line = line.trim().replaceFirst(RegExp(r'^(?:https?|tcp|tls):\s*'), '');
      final request = RegExp(
        r'^request: (GET|HEAD|POST) (.+) HTTP/\d(?:\.\d)?$',
      ).firstMatch(line);
      if (request != null) {
        flushRequest();
        requests++;
        _requestStarted = _watch.elapsedMilliseconds;
        _method = request.group(1);
        _target = request.group(2);
        _host = null;
        _agent = null;
        _cookie = false;
        _referer = false;
        _range = false;
        _emby = false;
        continue;
      }
      if (line.startsWith("header='")) {
        flushRequest();
        final header = line.substring(8).replaceFirst(RegExp(r"'$"), '');
        final status = RegExp(
          r'^HTTP/\d(?:\.\d)?\s+(\d{3})\b',
        ).firstMatch(header)?.group(1);
        if (status != null) {
          final code = int.parse(status);
          record(
            '响应 #$requests：HTTP $code；目标=$_lastDestination；'
            '请求至响应=${_watch.elapsedMilliseconds - _requestStarted} ms',
            level: code >= 400 ? LogLevel.error : LogLevel.info,
          );
        } else if (header.toLowerCase().startsWith('location:')) {
          final location = header.substring(9).trim();
          final uri = Uri.tryParse(location);
          // A relative Location cannot be compared without its current base.
          _expectedTarget = uri?.hasScheme == true
              ? requestTarget(location)
              : location.startsWith('/') && !location.startsWith('//')
              ? location
              : null;
          record(
            '重定向 #$requests：目标=${uri?.hasAuthority == true ? destination(uri!.authority) : '相对地址'}',
          );
        } else if (header.toLowerCase().startsWith('set-cookie:')) {
          record('响应 #$requests：收到媒体凭据');
        } else {
          final colon = header.indexOf(':');
          if (colon > 0) {
            final name = header.substring(0, colon).toLowerCase();
            if (const {
              'content-type',
              'content-length',
              'content-range',
              'content-encoding',
              'accept-ranges',
            }.contains(name)) {
              record(
                '响应 #$requests：$name=${redactLog(header.substring(colon + 1).trim())}',
              );
            }
          }
        }
        continue;
      }
      if (_method == null) continue;
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon).toLowerCase();
      final value = line.substring(colon + 1).trim();
      switch (name) {
        case 'host':
          _host = value;
        case 'user-agent':
          _agent = value;
        case 'cookie':
          _cookie = true;
        case 'referer':
          _referer = true;
        case 'range':
          _range = true;
        case 'x-emby-token' || 'x-emby-authorization':
          _emby = true;
      }
    }
  }

  void finish() {
    flushRequest();
    if (_events < eventLimit) {
      record(
        '$phase网络记录结束；请求=$requests 次；耗时=${_watch.elapsedMilliseconds} ms；'
        '外部响应正文=MPV 未提供',
      );
    }
    _finished = true;
    _target = null;
    _agent = null;
    _host = null;
    _expectedTarget = null;
  }
}
