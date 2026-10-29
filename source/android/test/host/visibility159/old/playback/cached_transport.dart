import 'dart:async';
import 'dart:io';
import '../core/models.dart';
import '../core/emby.dart' show newId;
import 'byte_cache.dart';
import 'cached_reader.dart';
import 'disc_cache.dart';
import 'disc_stream.dart';
import 'disc_transport.dart' show ExactHttpUri, discByteRange;

/// Opt-in raw-file caching around the original authenticated local transport.
/// Same-origin credentials remain exclusively in that transport. Signed URLs
/// remain byte-exact, and a resolved entry is never requested again this session.
class CachedPlaybackTransport {
  CachedPlaybackTransport({
    required this.address,
    required this.headers,
    required this.cache,
    required this.scope,
  });
  final String address, scope;
  final Map<String, String> headers;
  final PlaybackByteCache cache;
  late final reader = CachedMediaReader(
    open: _open,
    cache: cache,
    scope: scope,
  );
  HttpServer? _server;
  final _clients = <HttpClient>{};
  final _requests = <DiscReadCancellation>{};
  DiscReadCancellation? _demand;
  HttpResponse? _demandResponse;
  String? _resolved;
  String? _validator;
  String? failure;
  bool _closed = false;
  bool _bypass = false;
  final _token = newId();

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

  Future<DiscStreamSource> _open(
    String path,
    int start,
    DiscReadCancellation cancellation,
  ) async {
    if (failure != null) throw AppFailure(failure!);
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 30);
    _clients.add(client);
    void close() {
      _clients.remove(client);
      client.close(force: true);
    }

    cancellation.abort = close;
    try {
      var target = _resolved ?? address;
      final visited = <String>{};
      for (var hop = 0; hop < 8; hop++) {
        cancellation.check();
        if (_closed || !visited.add(target)) {
          throw const AppFailure('视频读取已取消或重定向循环');
        }
        final uri = ExactHttpUri(target);
        final request = await client
            .getUrl(uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        // These are source-specified media headers, never Emby account headers.
        headers.forEach(request.headers.set);
        request.headers.set('Accept-Encoding', 'identity');
        request.headers.set('Range', 'bytes=$start-');
        if (_validator != null && _validator!.startsWith('etag:')) {
          request.headers.set('If-Match', _validator!.substring(5));
        }
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        cancellation.check();
        final location = response.headers.value('location');
        if (const {301, 302, 303, 307, 308}.contains(response.statusCode) &&
            location != null) {
          if (_resolved != null) throw const AppFailure('已解析的片源地址发生跳转，请重新打开');
          target =
              RegExp(r'^https?://', caseSensitive: false).hasMatch(location)
              ? location
              : location.startsWith('//')
              ? '${uri.scheme}:$location'
              : uri.parsed.resolve(location).toString();
          await response.listen((_) {}).cancel();
          continue;
        }
        if (response.statusCode != 206 &&
            !(response.statusCode == 200 && start == 0)) {
          if (response.statusCode == 200) throw const _CacheUnavailable();
          failure = '视频读取返回 HTTP ${response.statusCode}，已停止自动重试';
          throw AppFailure(failure!);
        }
        final range = RegExp(
          r'^bytes (\d+)-(\d+)/(\d+)$',
        ).firstMatch(response.headers.value('content-range') ?? '');
        final total = range == null
            ? response.contentLength
            : int.parse(range[3]!);
        if (total <= start ||
            (response.statusCode == 206 &&
                (range == null ||
                    int.parse(range[1]!) != start ||
                    int.parse(range[2]!) != total - 1)) ||
            !const {
              null,
              'identity',
            }.contains(response.headers.value('content-encoding'))) {
          throw const _CacheUnavailable();
        }
        final type = (response.headers.contentType?.mimeType ?? '')
            .toLowerCase();
        if (response.statusCode == 200 ||
            type.contains('mpegurl') ||
            type.contains('dash+xml')) {
          throw const _CacheUnavailable();
        }
        final tag = response.headers.value('etag');
        final modified = response.headers.value('last-modified');
        var validModified = false;
        try {
          if (modified != null) {
            HttpDate.parse(modified);
            validModified = true;
          }
        } catch (_) {}
        final validator =
            tag != null && tag.startsWith('"') && tag.endsWith('"')
            ? 'etag:$tag'
            : validModified
            ? 'modified:$modified'
            : null;
        if (_resolved != null && validator != _validator) {
          throw const AppFailure('视频内容校验发生变化，请重新打开');
        }
        _resolved = target;
        _validator = validator;
        if (validator == null) cache.warning = '此片源没有可靠的文件校验标记，仅使用本次临时缓冲';
        return DiscStreamSource(
          start: start,
          total: total,
          bytes: response,
          validator: validator,
          close: (_) => close(),
        );
      }
      throw const AppFailure('视频重定向次数过多');
    } catch (_) {
      close();
      rethrow;
    }
  }

  Future<void> _serve(HttpRequest request) async {
    final cancellation = DiscReadCancellation();
    _requests.add(cancellation);
    unawaited(
      request.response.done.then(
        (_) => cancellation.cancel(),
        onError: (Object _) => cancellation.cancel(),
      ),
    );
    try {
      if (_closed ||
          request.uri.path != '/$_token' ||
          request.uri.hasQuery ||
          !const {'HEAD', 'GET'}.contains(request.method)) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      if (_bypass) {
        await _redirect(request);
        return;
      }
      final raw = request.headers.value('range');
      final initial =
          int.tryParse(
            RegExp(r'^bytes=(\d+)-').firstMatch(raw ?? '')?[1] ?? '',
          ) ??
          0;
      await reader.initialize(initial, cancellation);
      final span = discByteRange(raw, reader.total);
      if (span == null) {
        request.response.statusCode = 416;
        request.response.headers.set(
          'Content-Range',
          'bytes */${reader.total}',
        );
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        // A decoder's new range replaces its old range. Cancel a blocked old
        // body as well as a blocked socket flush, before reading the new offset.
        _demand?.cancel();
        _demandResponse?.deadline = Duration.zero;
        _demand = cancellation;
        _demandResponse = request.response;
      }
      final response = request.response;
      response.statusCode = raw == null ? 200 : 206;
      response.headers.set('Accept-Ranges', 'bytes');
      if (raw != null) {
        response.headers.set(
          'Content-Range',
          'bytes ${span.start}-${span.end}/${reader.total}',
        );
      }
      response.contentLength = span.end - span.start + 1;
      if (request.method == 'GET') {
        var at = span.start;
        while (at <= span.end) {
          cancellation.check();
          final bytes = await reader.read(
            at,
            (span.end - at + 1).clamp(1, CachedMediaReader.blockBytes),
            cancellation,
          );
          response.add(bytes);
          await response.flush();
          at += bytes.length;
        }
      }
      await response.close();
    } on _CacheUnavailable {
      _bypass = true;
      cache.warning = '此片源不支持可复用的字节缓存，沿用直接播放';
      await _redirect(request);
    } catch (error) {
      if (!_closed && !cancellation.cancelled) {
        failure ??= safeError(error);
      }
      try {
        request.response.statusCode = 502;
        await request.response.close();
      } catch (_) {}
    } finally {
      if (identical(_demand, cancellation)) {
        _demand = null;
        _demandResponse = null;
      }
      _requests.remove(cancellation);
    }
  }

  Future<void> _redirect(HttpRequest request) async {
    request.response.statusCode = 307;
    request.response.headers.set('Location', address);
    request.response.contentLength = 0;
    await request.response.close();
  }

  void seek() {
    // MPV owns cancellation of its old demand connection during seek. Only
    // stop speculation here; closing a demanded socket before the native seek
    // can be misreported as a real media failure.
    reader.stopWarming();
  }

  Future<void> close() async {
    _closed = true;
    for (final request in _requests.toList()) {
      request.cancel();
    }
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    await reader.close();
    await _server?.close(force: true);
  }
}

class _CacheUnavailable implements Exception {
  const _CacheUnavailable();
}
