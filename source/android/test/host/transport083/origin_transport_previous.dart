import 'dart:async';
import 'dart:io';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/http_diagnostics.dart';
import 'package:yingyu/core/models.dart';

/// Keeps account authentication within the configured Emby origin. libmpv
/// receives only a random loopback capability and ordinary media headers.
/// External Location values go straight to libmpv, without a preliminary GET.
class EmbyOriginTransport {
  EmbyOriginTransport(this.route, {this.log, this.onDisc});
  final PlaybackRoute route;
  final DiagnosticLog? log;
  final void Function(DiscKind kind, String address)? onDisc;
  bool discDetected = false;
  final _clients = <HttpClient>{};
  HttpServer? _server;
  bool _closed = false;
  String? rejection;
  // Locally generated proxy failures must not be attributed to the upstream.
  String? localFailure;
  int _requests = 0;
  Completer<String>? _resolved;
  final _redirectEntries = <String>{};
  String? _failure;
  late final String _path = '/${newId()}/stream';
  static const redirects = {301, 302, 303, 307, 308};

  Future<String> start() async {
    final target = Uri.parse(route.url);
    if (route.serverBase == null ||
        target.origin != route.serverBase!.origin ||
        route.sameOriginHeaders.isEmpty) {
      throw const AppFailure('Emby 同源播放身份未就绪');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw const AppFailure('播放已退出');
    }
    _server = server;
    server.serverHeader = null;
    server.listen(
      (request) => unawaited(_serve(request)),
      onError: (Object error) {
        record('Emby 同源监听异常：${error.runtimeType}；$error', error: true);
      },
    );
    record('启用 Emby 同源认证；本次播放只解析一次入口；外部目标缓存复用，失效后不自动重新解析；账户认证头不交给 MPV');
    return 'http://127.0.0.1:${server.port}$_path';
  }

  void record(String value, {bool error = false}) {
    if (_closed) return;
    log?.add(
      LogArea.network,
      redactLog(value, secrets: route.diagnosticSecrets),
      level: error ? LogLevel.error : LogLevel.info,
    );
  }

  Future<void> _serve(HttpRequest incoming) async {
    HttpClient? client;
    final requestId = log?.nextRequest('媒体') ?? '媒体${++_requests}';
    final watch = Stopwatch()..start();
    var stage = '校验本机请求';
    var transferred = 0;
    int? upstreamStatus;
    Completer<String>? resolving;
    try {
      if (_closed ||
          incoming.uri.path != _path ||
          incoming.uri.hasQuery ||
          !const {'GET', 'HEAD'}.contains(incoming.method)) {
        incoming.response.statusCode = HttpStatus.notFound;
        await incoming.response.close();
        return;
      }
      if (_failure != null) throw AppFailure(_failure!);
      final pending = _resolved;
      if (pending == null) {
        resolving = _resolved = Completer<String>();
        unawaited(resolving.future.then<void>((_) {}, onError: (Object _) {}));
      }
      final target = pending == null ? route.url : await pending.future;
      if (_closed) throw const AppFailure('播放已退出');
      if (_failure != null) throw AppFailure(_failure!);
      if (discDetected) {
        incoming.response.statusCode = 415;
        await incoming.response.close();
        return;
      }
      var uri = Uri.parse(target);
      if (uri.origin != route.serverBase!.origin) {
        incoming.response.statusCode = 302;
        incoming.response.headers.set('Location', target);
        incoming.response.contentLength = 0;
        await incoming.response.close();
        record('$requestId 复用已解析的媒体目标；未重新访问 Emby/STRM 入口');
        return;
      }
      client = HttpClient()
        ..autoUncompress = false
        ..connectionTimeout = const Duration(seconds: 30);
      _clients.add(client);
      final active = client;
      unawaited(
        incoming.response.done.then(
          (_) => active.close(force: true),
          onError: (Object _) => active.close(force: true),
        ),
      );
      for (var hop = 0; hop < 8; hop++) {
        if (_redirectEntries.contains(uri.toString())) {
          throw const AppFailure('媒体重定向返回了已访问入口，已停止重复解析');
        }
        final hopId = '$requestId.${hop + 1}';
        final hopWatch = Stopwatch()..start();
        // Each same-origin redirect is checked before creating a new request.
        if (uri.origin != route.serverBase!.origin) {
          throw const AppFailure('Emby 同源传输遇到未验证的目标');
        }
        stage = '建立同源连接';
        upstreamStatus = null;
        record(
          '$hopId 开始：${incoming.method}；目标=Emby 同源；协议=${uri.scheme}；'
          '连接超时=30 秒；自动跳转=关闭',
        );
        final request = await client
            .openUrl(incoming.method, uri)
            .timeout(const Duration(seconds: 30));
        request.followRedirects = false;
        route.headers.forEach(request.headers.set);
        route.sameOriginHeaders.forEach(request.headers.set);
        for (final name in [
          'range',
          'if-range',
          'if-none-match',
          'if-modified-since',
        ]) {
          final values = incoming.headers[name];
          if (values != null) request.headers.set(name, values);
        }
        request.headers.set('Accept-Encoding', 'identity');
        stage = '等待响应头';
        record(
          '$hopId 请求头已设置：${requestHeaderFacts(request.headers.value)}；'
          'Accept-Encoding=identity；连接就绪耗时=${hopWatch.elapsedMilliseconds} ms',
        );
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        upstreamStatus = response.statusCode;
        final network = response.connectionInfo?.remoteAddress.type;
        record(
          '$hopId 响应：HTTP ${response.statusCode}；响应头耗时=${hopWatch.elapsedMilliseconds} ms；'
          '网络=${network == InternetAddressType.IPv6
              ? 'IPv6'
              : network == InternetAddressType.IPv4
              ? 'IPv4'
              : '未捕获'}；'
          '${responseFacts(response.headers.value, secrets: route.diagnosticSecrets)}',
          error: response.statusCode >= 400,
        );
        final location = response.headers.value('location');
        record(
          '$hopId 响应附加信息：Location=${location == null ? '无' : '有'}；'
          '响应 Cookie 数量=${response.headers['set-cookie']?.length ?? 0} 项（值不记录）',
        );
        if (redirects.contains(response.statusCode) && location != null) {
          _redirectEntries.add(uri.toString());
          final next = uri.resolve(location);
          if (!const {'http', 'https'}.contains(next.scheme) ||
              next.host.isEmpty) {
            throw const AppFailure('媒体重定向协议不受支持');
          }
          final discKind = discAddressKind(location);
          if (onDisc != null && discKind != DiscKind.none) {
            final exact =
                RegExp(r'^https?://', caseSensitive: false).hasMatch(location)
                ? location
                : location.startsWith('//')
                ? '${uri.scheme}:$location'
                : next.toString();
            discDetected = true;
            resolving?.complete(exact);
            record('$hopId STRM/Emby 跳转目标识别为原盘；切换原盘读取组件');
            onDisc!(discKind, exact);
            incoming.response.statusCode = 415;
            await incoming.response.close();
            return;
          }
          if (next.origin == route.serverBase!.origin) {
            record('$hopId 重定向：同源；下一跳将重新校验来源');
            if (hop == 7) throw const AppFailure('媒体重定向次数过多');
            // Cancelling the response releases this redirect without fetching
            // an arbitrary response body or consuming a target media URL.
            await response.listen((_) {}).cancel();
            uri = next;
            continue;
          }
          incoming.response.statusCode = response.statusCode;
          // Preserve every byte of an absolute signed Location.
          final rawLocation =
              RegExp(r'^https?://', caseSensitive: false).hasMatch(location)
              ? location
              : location.startsWith('//')
              ? '${uri.scheme}:$location'
              : next.toString();
          incoming.response.headers.set('Location', rawLocation);
          resolving?.complete(rawLocation);
          incoming.response.contentLength = 0;
          record(
            '$hopId 重定向：外部；交给 MPV；未跟随、未转发账户认证头；耗时=${watch.elapsedMilliseconds} ms',
          );
          await incoming.response.close();
          return;
        }
        incoming.response.statusCode = response.statusCode;
        if (response.statusCode >= 400) {
          stage = '读取错误正文';
          final body = await readDiagnosticBody(
            response,
            encoding: response.headers.value('content-encoding') ?? '',
          );
          final details = recordHttpFailure(
            log,
            hopId,
            body,
            secrets: route.diagnosticSecrets,
          );
          rejection = details.summary;
          final error = AppFailure(
            'HTTP ${response.statusCode}；入口解析失败，已停止自动重试',
          );
          _failure = error.message;
          if (resolving != null && !resolving.isCompleted) {
            resolving.completeError(error);
          }
          record(
            '$hopId 结束：HTTP ${response.statusCode}；总耗时=${watch.elapsedMilliseconds} ms；正文=${body.state}',
            error: true,
          );
          incoming.response.headers.contentType = ContentType.text;
          incoming.response.write('HTTP ${response.statusCode}');
          await incoming.response.close();
          return;
        }
        final disposition = response.headers.value('content-disposition') ?? '';
        final contentType = response.headers.value('content-type') ?? '';
        if (onDisc != null &&
            const {200, 206}.contains(response.statusCode) &&
            (contentType.toLowerCase().contains('iso9660') ||
                RegExp(
                  r'\.iso(?:[";\s]|$)',
                  caseSensitive: false,
                ).hasMatch(disposition))) {
          discDetected = true;
          resolving?.complete(uri.toString());
          record('$hopId 响应头识别为 ISO；切换原盘读取组件');
          onDisc!(DiscKind.iso, uri.toString());
          incoming.response.statusCode = 415;
          await incoming.response.close();
          return;
        }
        Stream<List<int>> body = response;
        if (onDisc != null &&
            const {200, 206}.contains(response.statusCode) &&
            (incoming.headers.value('range') == null ||
                RegExp(
                  r'^bytes=0-',
                ).hasMatch(incoming.headers.value('range')!))) {
          // Sniff only the already requested same-origin response; replay the
          // same bytes for normal video. No preflight or second external GET.
          stage = '读取首块数据';
          final iterator = StreamIterator(
            response.timeout(const Duration(seconds: 30)),
          );
          final chunks = <List<int>>[];
          var length = 0;
          while (length < 65536 && await iterator.moveNext()) {
            chunks.add(iterator.current);
            length += iterator.current.length;
          }
          if (isUdfDiscPrefix(chunks.expand((c) => c).take(65536).toList())) {
            discDetected = true;
            resolving?.complete(uri.toString());
            record('$hopId 实际响应识别到 UDF 卷标；切换原盘读取组件');
            onDisc!(DiscKind.iso, uri.toString());
            await iterator.cancel();
            incoming.response.statusCode = 415;
            await incoming.response.close();
            return;
          }
          body = () async* {
            try {
              for (final chunk in chunks) {
                yield chunk;
              }
              while (await iterator.moveNext()) {
                yield iterator.current;
              }
            } finally {
              await iterator.cancel();
            }
          }();
        }
        for (final name in [
          'content-type',
          'content-length',
          'content-range',
          'content-encoding',
          'accept-ranges',
          'etag',
          'last-modified',
        ]) {
          final values = response.headers[name];
          if (values != null) incoming.response.headers.set(name, values);
        }
        resolving?.complete(uri.toString());
        stage = '转发响应正文';
        await incoming.response.addStream(
          body.timeout(const Duration(seconds: 30)).map((chunk) {
            transferred += chunk.length;
            localFailure = null;
            return chunk;
          }),
        );
        await incoming.response.close();
        record(
          '$hopId 完成：HTTP ${response.statusCode}；转发=$transferred 字节；总耗时=${watch.elapsedMilliseconds} ms',
        );
        return;
      }
    } catch (error, stack) {
      if (!_closed && error is TimeoutException) {
        localFailure =
            '媒体取流超时：$stage（30 秒）；'
            '${upstreamStatus == null ? '尚未收到上游 HTTP 响应' : '上游 HTTP $upstreamStatus'}；'
            '已转发 $transferred 字节';
        // An unresolved entry is never opened again. A later body interruption
        // retains the existing ability to read ranges from the resolved target.
        if (resolving != null && !resolving.isCompleted) {
          _failure = localFailure;
        }
      }
      if (resolving != null && !resolving.isCompleted) {
        resolving.completeError(error, stack);
      }
      if (!_closed) {
        record(
          '$requestId 未完成：阶段=$stage；异常=${error.runtimeType}；${localFailure ?? error}；'
          '上游状态=${upstreamStatus == null ? '未捕获' : 'HTTP $upstreamStatus'}；'
          '已转发=$transferred 字节；耗时=${watch.elapsedMilliseconds} ms',
          error: true,
        );
        try {
          incoming.response.statusCode =
              error is TimeoutException || localFailure != null
              ? HttpStatus.gatewayTimeout
              : HttpStatus.badGateway;
          record(
            '$requestId 本机转发返回 HTTP ${incoming.response.statusCode}；不是上游响应状态',
            error: true,
          );
          await incoming.response.close();
        } catch (_) {
          /* The decoder may already have closed the socket. */
        }
      }
    } finally {
      client?.close(force: true);
      if (client != null) _clients.remove(client);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
    await _server?.close(force: true);
  }
}

bool isUdfDiscPrefix(List<int> bytes) {
  for (var sector = 16; sector < 32; sector++) {
    final at = sector * 2048 + 1;
    if (bytes.length >= at + 5) {
      final marker = String.fromCharCodes(bytes.sublist(at, at + 5));
      if (marker == 'NSR02' || marker == 'NSR03') return true;
    }
  }
  return false;
}
