import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import '../core/emby.dart' show newId;
import '../core/models.dart';
import 'disc_transport.dart' show ExactHttpUri, discByteRange;

bool startupRangeCandidate(
  String address, {
  Map<String, String> headers = const {},
}) {
  final uri = Uri.tryParse(address);
  if (uri == null ||
      uri.userInfo.isNotEmpty ||
      headers.keys.any((key) => key.toLowerCase() == 'cookie')) {
    return false;
  }
  final path = uri.path.toLowerCase();
  return const ['.mp4', '.m4v', '.mov'].any(path.endsWith);
}

/// Preserve a validated initial response across MP4's tiny end-of-file probe.
/// No speculative request, persistent cache, entry refresh or playback timer.
class StartupPlaybackTransport {
  StartupPlaybackTransport({
    required this.address,
    required this.headers,
    this.onDiagnostic,
  });
  final String address;
  final Map<String, String> headers;
  final void Function(String)? onDiagnostic;
  static const maxBytes = 8 * 1024 * 1024;
  static const _retainedPrefix = maxBytes;
  final _clients = <HttpClient>{};
  Completer<void> _clientChanged = Completer<void>();
  final _token = newId();
  HttpServer? _server;
  Completer<String>? _resolved;
  _StartupBody? _head;
  _StartupLease? _demand;
  bool _closed = false, _bypass = false, _startup = true, _tailSeen = false;
  Timer? _idleTimer;
  int openedResponses = 0, peakResponses = 0, reusedBytes = 0;
  int _peakBytes = 0;
  int _reuseUntil = 0;
  int get retainedBytes => _head?.retained ?? 0;
  int get peakBytes => _peakBytes;
  String? failure;

  Future<String> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw const AppFailure('播放已退出');
    }
    _server = server;
    server.serverHeader = null;
    server.listen((request) => unawaited(_serve(request)));
    return 'http://127.0.0.1:${server.port}/$_token';
  }

  Future<_StartupRemote> _open(
    String method,
    String? range,
    _StartupLease lease, {
    String? tag,
    Map<String, List<String>> conditions = const {},
  }) async {
    final pending = _resolved;
    final first = pending == null ? (_resolved = Completer<String>()) : null;
    if (first != null) {
      unawaited(first.future.then<void>((_) {}, onError: (Object _) {}));
    }
    var target = pending == null ? address : await pending.future;
    lease.check();
    while (_clients.length >= 2) {
      await Future.any([_clientChanged.future, lease.done.future]);
      lease.check();
    }
    if (_closed) throw const AppFailure('播放已退出');
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30);
    _clients.add(client);
    if (_clients.length > peakResponses) peakResponses = _clients.length;
    void cancel() {
      if (_clients.remove(client)) {
        _clientChanged.complete();
        _clientChanged = Completer<void>();
      }
      client.close(force: true);
    }

    lease.onCancel = cancel;
    try {
      final visited = <String>{};
      for (var hop = 0; hop < 8; hop++) {
        lease.check();
        if (_closed || !visited.add(target)) {
          throw const AppFailure('起播读取已取消或重定向循环');
        }
        final uri = ExactHttpUri(target);
        final request = await client
            .openUrl(method, uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        headers.forEach(request.headers.set);
        conditions.forEach(request.headers.set);
        request.headers.set('Accept-Encoding', 'identity');
        if (range != null) request.headers.set('Range', range);
        if (tag != null) request.headers.set('If-Range', tag);
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        lease.check();
        if (response.statusCode >= 200 &&
            response.statusCode < 400 &&
            response.headers['set-cookie']?.isNotEmpty == true) {
          first?.complete(target);
          openedResponses++;
          return _StartupRemote(response, cancel, nativeOnly: true);
        }
        final location = response.headers.value('location');
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode) &&
            location != null) {
          if (pending != null) {
            throw const AppFailure('已解析的媒体地址发生跳转，请重新打开');
          }
          target = uri.resolve(location).toString();
          await response.listen((_) {}).cancel();
          continue;
        }
        first?.complete(target);
        openedResponses++;
        return _StartupRemote(response, cancel);
      }
      throw const AppFailure('媒体重定向次数过多');
    } catch (error) {
      cancel();
      if (error is HandshakeException) {
        if (first != null && !first.isCompleted) first.complete(target);
        throw const _NativeStartupFallback();
      }
      if (first != null && !first.isCompleted) first.completeError(error);
      rethrow;
    }
  }

  void _headers(HttpResponse to, HttpClientResponse from) {
    to.statusCode = from.statusCode;
    if (from.contentLength >= 0) to.contentLength = from.contentLength;
    for (final name in const [
      'content-type',
      'content-range',
      'accept-ranges',
      'etag',
      'last-modified',
      'content-encoding',
    ]) {
      final value = from.headers.value(name);
      if (value != null) to.headers.set(name, value);
    }
  }

  Future<void> _redirect(HttpRequest request) async {
    final target = await _resolved!.future;
    request.response.statusCode = 307;
    request.response.headers.set('Location', target);
    request.response.contentLength = 0;
    await request.response.close();
  }

  Future<void> _unqualified(HttpRequest request, _StartupRemote remote) async {
    if (remote.response.statusCode < 200 || remote.response.statusCode >= 300) {
      _headers(request.response, remote.response);
      if (request.method == 'GET') {
        await request.response.addStream(remote.response);
      }
      await request.response.close();
      return;
    }
    final type = remote.response.headers.contentType?.mimeType ?? '';
    if (type.contains('mpegurl') || type.contains('dash+xml')) {
      await _redirect(request);
      return;
    }
    if (request.method == 'HEAD') {
      _headers(request.response, remote.response);
      await request.response.close();
      return;
    }
    final iterator = StreamIterator(remote.response);
    try {
      final more = await iterator.moveNext().timeout(
        const Duration(seconds: 30),
      );
      final first = more ? iterator.current : const <int>[];
      var prefix = first.take(128).toList();
      if (prefix.length >= 3 &&
          prefix[0] == 239 &&
          prefix[1] == 187 &&
          prefix[2] == 191) {
        prefix = prefix.sublist(3);
      }
      final text = String.fromCharCodes(prefix).trimLeft();
      if (text.startsWith('#EXTM3U') ||
          text.startsWith('<?xml') ||
          text.startsWith('<MPD')) {
        await iterator.cancel();
        await _redirect(request);
        return;
      }
      _headers(request.response, remote.response);
      await request.response.addStream(() async* {
        if (more) yield first;
        while (await iterator.moveNext().timeout(const Duration(seconds: 30))) {
          yield iterator.current;
        }
      }());
      await request.response.close();
    } finally {
      await iterator.cancel();
    }
  }

  Future<void> _serve(HttpRequest request) async {
    if (_closed ||
        request.uri.path != '/$_token' ||
        request.uri.hasQuery ||
        !const {'GET', 'HEAD'}.contains(request.method)) {
      try {
        request.response.statusCode = 404;
        await request.response.close();
      } catch (_) {}
      return;
    }
    final lease = _StartupLease(request.response);
    _StartupRemote? remote;
    _idleTimer?.cancel();
    if (request.method == 'GET') {
      _demand?.cancel();
      _demand = lease;
    }
    unawaited(
      request.response.done.then(
        (_) => lease.cancel(),
        onError: (Object _) => lease.cancel(),
      ),
    );
    try {
      if (failure != null) throw AppFailure(failure!);
      if (_bypass) {
        await _redirect(request);
        return;
      }
      final raw = request.headers.value('range');
      final conditions = <String, List<String>>{};
      for (final key in const [
        'if-range',
        'if-match',
        'if-none-match',
        'if-modified-since',
      ]) {
        final values = request.headers[key];
        if (values != null) {
          conditions[key] = values;
        }
      }
      final head = _head;
      if (head != null) {
        if (head.error != null) {
          _bypass = true;
          await head.close();
          _head = null;
          onDiagnostic?.call('起播保留响应已不可用；本次原生范围请求沿用直接读取，入口不重访');
          await _redirect(request);
          return;
        }
        if (conditions.keys.any((key) => key != 'if-range') ||
            (conditions['if-range'] != null &&
                conditions['if-range']!.join() != head.tag)) {
          _bypass = true;
          await head.close();
          _head = null;
          await _redirect(request);
          return;
        }
        final span = discByteRange(raw, head.total);
        if (span == null) {
          request.response.statusCode = 416;
          request.response.headers.set(
            'Content-Range',
            'bytes */${head.total}',
          );
          request.response.contentLength = 0;
          await request.response.close();
          return;
        }
        final tail =
            _startup &&
            span.start >= head.total - 65536 &&
            span.end - span.start < 65536;
        if (tail) {
          remote = await _open(
            request.method,
            raw,
            lease,
            tag: head.tag,
            conditions: conditions,
          );
          if (remote.nativeOnly) {
            _bypass = true;
            await head.close();
            _head = null;
            await _redirect(request);
            return;
          }
          final identity = remote.identity;
          if (identity == null ||
              identity.total != head.total ||
              identity.tag != head.tag ||
              identity.start != span.start ||
              identity.end != span.end) {
            throw const AppFailure('起播索引的文件校验或字节范围发生变化');
          }
          _tailSeen = true;
          onDiagnostic?.call('起播索引小范围读取；原正文响应保持，最多两路响应');
          _headers(request.response, remote.response);
          if (request.method == 'GET') {
            await request.response.addStream(remote.response);
          }
          await request.response.close();
          return;
        }
        final reusable =
            span.start >= head.first &&
            (span.start == 0 ||
                (_startup && _tailSeen && span.start < head.published) ||
                (!_startup && span.start == head.consumed));
        if (reusable) {
          if (_tailSeen && span.start > 0) {
            _startup = false;
            _reuseUntil = head.published;
            onDiagnostic?.call('起播正文已复用原响应；未重新请求正文起点；前方缓冲上限=8 MiB');
          }
          await _serveHead(request, head, span.start, span.end, lease);
          return;
        }
        // A real seek leaves the bounded startup path. Native direct reads
        // reuse the resolved target, never the account/STRM entry.
        _bypass = true;
        await head.close();
        _head = null;
        await _redirect(request);
        return;
      }
      remote = await _open(request.method, raw, lease, conditions: conditions);
      if (remote.nativeOnly) {
        _bypass = true;
        onDiagnostic?.call('起播响应交回原生会话处理；Cookie 不改写到本机地址');
        await _redirect(request);
        return;
      }
      final identity = remote.identity;
      final initial =
          request.method == 'GET' &&
          (raw == null || RegExp(r'^bytes=0-(?:\d*)$').hasMatch(raw));
      if (initial &&
          identity != null &&
          identity.start == 0 &&
          identity.end == identity.total - 1 &&
          identity.total >= 2 * maxBytes) {
        final created = _StartupBody(
          remote,
          identity.total,
          identity.tag,
          onPeak: (value) {
            if (value > _peakBytes) _peakBytes = value;
          },
          onDiagnostic: onDiagnostic,
        );
        _head = created;
        lease.onCancel =
            null; // The bounded body, rather than this socket, owns it.
        remote = null;
        created.start();
        onDiagnostic?.call('起播正文响应已保留；前方缓冲上限=8 MiB；不增加起播等待目标');
        await _serveHead(request, created, 0, identity.end, lease);
        return;
      }
      // Forward unqualified binary responses without a second upstream GET.
      // A mislabeled playlist must retain its real URL as its relative base.
      _bypass = true;
      final validator = remote.response.headers.value('etag');
      final strong =
          validator != null &&
          validator.startsWith('"') &&
          validator.endsWith('"');
      onDiagnostic?.call(
        '起播响应未启用复用：HTTP=${remote.response.statusCode}；'
        '强文件校验=$strong；'
        '不增加缓存等待目标',
      );
      await _unqualified(request, remote);
    } catch (error) {
      if (!_closed && !lease.cancelled && error is _NativeStartupFallback) {
        _bypass = true;
        await _head?.close();
        _head = null;
        onDiagnostic?.call('起播桥接 TLS 不适用，交回原生读取；未修改证书校验设置或重新解析入口');
        try {
          await _redirect(request);
        } catch (_) {}
        return;
      }
      if (!_closed && !lease.cancelled) {
        failure ??= error is AppFailure
            ? error.message
            : '起播正文读取失败（${error.runtimeType}）';
      }
      try {
        request.response.statusCode = 502;
        request.response.contentLength = 0;
      } catch (_) {}
      try {
        await request.response.close();
      } catch (_) {}
      lease.cancel();
    } finally {
      remote?.close();
      lease.onCancel = null;
      if (identical(_demand, lease)) _demand = null;
      if (!_closed && _startup && _demand == null && _head != null) {
        _idleTimer = Timer(const Duration(seconds: 8), () {
          _bypass = true;
          unawaited(_head?.close());
        });
      }
    }
  }

  Future<void> _serveHead(
    HttpRequest request,
    _StartupBody head,
    int start,
    int end,
    _StartupLease lease,
  ) async {
    final response = request.response;
    response.statusCode = request.headers.value('range') == null ? 200 : 206;
    response.contentLength = end - start + 1;
    response.headers.set('Accept-Ranges', 'bytes');
    final type = head.remote.response.headers.value('content-type');
    if (type != null) {
      response.headers.set('Content-Type', type);
    } else {
      response.headers.contentType = ContentType.binary;
    }
    response.headers.set('ETag', head.tag);
    if (response.statusCode == 206) {
      response.headers.set('Content-Range', 'bytes $start-$end/${head.total}');
    }
    if (request.method == 'GET') {
      var at = start;
      while (at <= end) {
        lease.check();
        final bytes = await head.read(at, end - at + 1, lease);
        lease.check();
        response.add(bytes);
        await response.flush();
        if (_reuseUntil > at) {
          reusedBytes += (at + bytes.length).clamp(at, _reuseUntil) - at;
        }
        at += bytes.length;
        head.consumed = at;
        if (!_startup || at >= _retainedPrefix) {
          _startup = false;
          head.releaseBefore(at);
        }
      }
    }
    await response.close();
  }

  Future<void> close() async {
    _closed = true;
    _idleTimer?.cancel();
    _demand?.cancel();
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
    _clientChanged.complete();
    _clientChanged = Completer<void>();
    await _head?.close();
    await _server?.close(force: true);
  }
}

class _NativeStartupFallback implements Exception {
  const _NativeStartupFallback();
}

class _StartupRemote {
  _StartupRemote(this.response, this.close, {this.nativeOnly = false});
  final bool nativeOnly;
  final HttpClientResponse response;
  final void Function() close;
  ({int start, int end, int total, String tag})? get identity {
    final range = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(response.headers.value('content-range') ?? '');
    final tag = response.headers.value('etag');
    final type = response.headers.contentType?.mimeType ?? '';
    if (nativeOnly ||
        response.statusCode != 206 ||
        range == null ||
        tag == null ||
        !tag.startsWith('"') ||
        !tag.endsWith('"') ||
        !const {
          null,
          'identity',
        }.contains(response.headers.value('content-encoding')) ||
        type.contains('mpegurl') ||
        type.contains('dash+xml') ||
        type.contains('multipart')) {
      return null;
    }
    final start = int.parse(range[1]!), end = int.parse(range[2]!);
    final total = int.parse(range[3]!);
    if (start < 0 ||
        end < start ||
        total <= end ||
        response.contentLength != end - start + 1) {
      return null;
    }
    return (start: start, end: end, total: total, tag: tag);
  }
}

class _StartupLease {
  _StartupLease(this.response);
  final HttpResponse response;
  final done = Completer<void>();
  bool cancelled = false;
  void Function()? onCancel;
  void check() {
    if (cancelled) throw const AppFailure('起播请求已取消');
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    done.complete();
    onCancel?.call();
    try {
      response.deadline = Duration.zero;
    } catch (_) {}
  }
}

class _StartupPage {
  _StartupPage(this.start, this.bytes);
  final int start;
  final Uint8List bytes;
}

class _StartupBody {
  _StartupBody(
    this.remote,
    this.total,
    this.tag, {
    required this.onPeak,
    this.onDiagnostic,
  });
  final _StartupRemote remote;
  final int total;
  final String tag;
  final void Function(int) onPeak;
  final void Function(String)? onDiagnostic;
  final _clock = Stopwatch()..start();
  Timer? _timer;
  int _lastReport = 0, _lastReceived = 0;
  bool _networkWait = false;
  final pages = ListQueue<_StartupPage>();
  Completer<void> changed = Completer<void>();
  StreamIterator<List<int>>? _iterator;
  Future<void>? _job;
  int published = 0, consumed = 0, retained = 0, peak = 0;
  bool closed = false;
  Object? error;
  int get first => pages.isEmpty ? published : pages.first.start;
  void pulse() {
    changed.complete();
    changed = Completer<void>();
  }

  void start() {
    if (onDiagnostic != null) {
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _report());
    }
    _job = _produce();
  }

  void _report() {
    final now = _clock.elapsedMilliseconds;
    onDiagnostic?.call(
      '起播上游正文观察：窗口=${now - _lastReport} ms；'
      '新增接收=${published - _lastReceived} 字节；当前暂存=$retained 字节；'
      '等待上游=$_networkWait；缓冲已满=${retained >= StartupPlaybackTransport.maxBytes}；'
      '包含本机背压，非线路测速',
    );
    _lastReport = now;
    _lastReceived = published;
  }

  Future<void> _produce() async {
    final iterator = _iterator = StreamIterator(remote.response);
    try {
      while (!closed) {
        _networkWait = true;
        final bool more;
        try {
          more = await iterator.moveNext().timeout(const Duration(seconds: 30));
        } finally {
          _networkWait = false;
        }
        if (!more) break;
        final bytes = iterator.current;
        var at = 0;
        while (!closed && at < bytes.length) {
          if (retained >= StartupPlaybackTransport.maxBytes) {
            await changed.future;
            continue;
          }
          final count = (bytes.length - at)
              .clamp(0, 65536)
              .clamp(0, StartupPlaybackTransport.maxBytes - retained);
          if (published + count > total) throw const AppFailure('起播正文超出声明长度');
          final Uint8List page;
          if (bytes is Uint8List && bytes.length <= 65536) {
            // Incoming socket chunks may be retained. Never mutate them or
            // recycle a page while an outgoing socket can still reference it.
            page = Uint8List.sublistView(bytes, at, at + count);
          } else {
            page = Uint8List(count)..setRange(0, count, bytes, at);
          }
          pages.add(_StartupPage(published, page));
          at += count;
          published += count;
          retained += count;
          if (retained > peak) {
            peak = retained;
            onPeak(peak);
          }
          pulse();
        }
      }
      if (!closed && published != total) throw const AppFailure('起播正文提前结束');
    } catch (caught) {
      if (!closed) error = caught;
    } finally {
      _timer?.cancel();
      pulse();
    }
  }

  Future<Uint8List> read(int at, int length, _StartupLease lease) async {
    while (true) {
      lease.check();
      if (closed || at < first) throw const AppFailure('起播缓冲范围已失效');
      for (final page in pages) {
        if (at >= page.start && at < page.start + page.bytes.length) {
          final offset = at - page.start;
          return Uint8List.sublistView(
            page.bytes,
            offset,
            offset + length.clamp(0, page.bytes.length - offset),
          );
        }
      }
      if (error != null) throw error!;
      await Future.any([changed.future, lease.done.future]);
    }
  }

  void releaseBefore(int at) {
    while (pages.isNotEmpty &&
        pages.first.start + pages.first.bytes.length <= at) {
      retained -= pages.removeFirst().bytes.length;
    }
    pulse();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    _timer?.cancel();
    remote.close();
    pulse();
    try {
      await _iterator?.cancel();
    } catch (_) {}
    await _job;
    pages.clear();
    retained = 0;
  }
}
