import 'dart:io';
import '../core/log.dart';
import '../core/http_diagnostics.dart';
import '../core/models.dart';

/// Diagnostic builds only: compare a rejected, ordinary same-origin Emby route
/// through Dart HTTP. Never follow redirects or read the external signed media.
Future<void> inspectRejectedRoute(
  PlaybackRoute route,
  DiagnosticLog log, {
  bool Function()? cancelled,
  Map<String, String> embyHeaders = const {},
}) async {
  if (!log.enabled || route.diagnosticCanonicalUrl == null) return;
  final base = route.serverBase;
  if (base == null) return;
  final candidates = <String, String>{'播放器同一入口': route.url};
  if (route.diagnosticCanonicalUrl != route.url) {
    candidates['标准原文件入口'] = route.diagnosticCanonicalUrl!;
  }
  if (embyHeaders.isNotEmpty) candidates['同源认证头入口'] = route.url;
  for (final candidate in candidates.entries) {
    if (cancelled?.call() == true) break;
    final uri = Uri.parse(candidate.value);
    if (uri.origin != base.origin) continue;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final requestId = log.nextRequest('对比');
    final watch = Stopwatch()..start();
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      request.followRedirects = false;
      route.headers.forEach(request.headers.set);
      if (candidate.key == '同源认证头入口') {
        // This request cannot follow a Location. Account headers are never
        // supplied to libmpv or a different origin.
        embyHeaders.forEach(request.headers.set);
      }
      client.userAgent = route.headers.entries
          .where((e) => e.key.toLowerCase() == 'user-agent')
          .map((e) => e.value)
          .firstOrNull;
      request.headers.set('Range', 'bytes=0-0');
      log.add(
        LogArea.network,
        '$requestId 首跳对比/${candidate.key}：GET；${requestHeaderFacts(request.headers.value)}；自动跳转=关闭',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final location = response.headers.value('location');
      final redirect = location == null
          ? '无'
          : uri.resolve(location).origin == base.origin
          ? '同源'
          : '外部';
      log.add(
        LogArea.network,
        '$requestId 首跳对比/${candidate.key}：HTTP ${response.statusCode}；跳转=$redirect（不跟随）；'
        '响应头耗时=${watch.elapsedMilliseconds} ms；${responseFacts(response.headers.value, secrets: route.diagnosticSecrets)}',
      );
      if (response.statusCode >= 400) {
        final body = await readDiagnosticBody(response);
        recordHttpFailure(
          log,
          requestId,
          body,
          secrets: route.diagnosticSecrets,
        );
      } else {
        await response.listen((_) {}).cancel();
      }
    } catch (error) {
      log.add(
        LogArea.network,
        '$requestId 首跳对比/${candidate.key}：${error.runtimeType}；'
        '${redactLog(error.toString(), secrets: route.diagnosticSecrets)}；耗时=${watch.elapsedMilliseconds} ms',
        level: LogLevel.warning,
      );
    } finally {
      client.close(force: true);
    }
  }
  await log.flush();
}
