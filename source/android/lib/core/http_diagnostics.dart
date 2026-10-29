import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'log.dart';

class DiagnosticBody {
  DiagnosticBody(this.bytes, this.state, {this.failure});
  final List<int> bytes;
  final String state;
  final String? failure;
}

Future<DiagnosticBody> readDiagnosticBody(
  Stream<List<int>> stream, {
  int limit = 16384,
  Duration timeout = const Duration(seconds: 3),
  String encoding = '',
}) async {
  final bytes = <int>[];
  final decoded = switch (encoding.trim().toLowerCase()) {
    'gzip' => gzip.decoder.bind(stream),
    'deflate' => zlib.decoder.bind(stream),
    _ => stream,
  };
  final iterator = StreamIterator(decoded);
  final watch = Stopwatch()..start();
  var state = '完整';
  String? failure;
  try {
    while (true) {
      final remainingTime = timeout - watch.elapsed;
      if (remainingTime <= Duration.zero) {
        state = '读取超时';
        break;
      }
      if (!await iterator.moveNext().timeout(remainingTime)) break;
      final part = iterator.current;
      final remaining = limit - bytes.length;
      bytes.addAll(part.take(remaining));
      if (part.length > remaining) {
        state = '已截断';
        break;
      }
      if (watch.elapsed >= timeout) {
        state = '读取超时';
        break;
      }
    }
  } on TimeoutException {
    state = '读取超时';
  } catch (error) {
    state = '读取中断';
    failure = error.runtimeType.toString();
  } finally {
    // A cancelled/broken stream must not replace the actual HTTP status.
    try {
      await iterator.cancel().timeout(const Duration(seconds: 1));
    } catch (error) {
      failure ??= error.runtimeType.toString();
    }
  }
  return DiagnosticBody(bytes, state, failure: failure);
}

class HttpFailureDetails {
  HttpFailureDetails(this.format, this.structure, this.fields);
  final String format, structure;
  final List<String> fields;
  String get summary => fields.isEmpty
      ? '服务端错误说明未捕获（$format）'
      : '服务端错误原文（已脱敏）：\n${fields.join('\n')}';
}

/// Extract actual error fields rather than inferring a cause from keywords.
/// Unknown JSON values, stack traces, headers and credentials are not exported.
HttpFailureDetails describeHttpFailure(
  List<int> bytes, {
  Iterable<String> secrets = const [],
}) {
  String scrub(String value) => redactLog(value, secrets: secrets);
  final raw = utf8.decode(bytes, allowMalformed: true);
  if (raw.trim().isEmpty) return HttpFailureDetails('空正文', '无', []);
  final fields = <String>[];
  const leaves = {
    'message',
    'msg',
    'detail',
    'details',
    'reason',
    'error_description',
    'description',
    'errormessage',
    'error_message',
    'error_msg',
    'exceptiontype',
    'title',
    'errorcode',
    'error_code',
    'code',
    'status',
    'statuscode',
    'status_code',
    'success',
  };
  const containers = {'responsestatus', 'error', 'errors', 'response', 'data'};
  int visited = 0;
  void collect(Object? value, String path, int depth) {
    if (depth > 4 || visited++ > 40 || fields.length >= 12) return;
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase();
        if (!leaves.contains(key) && !containers.contains(key)) continue;
        final label = path.isEmpty
            ? entry.key.toString()
            : '$path.${entry.key}';
        if (entry.value is String ||
            entry.value is num ||
            entry.value is bool) {
          fields.add('$label: ${scrub('${entry.value}')}');
        } else {
          collect(entry.value, label, depth + 1);
        }
        if (fields.length >= 12) break;
      }
    } else if (value is List) {
      for (var i = 0; i < value.length && i < 8; i++) {
        collect(value[i], '$path[$i]', depth + 1);
      }
    } else if (value is String) {
      fields.add('${path.isEmpty ? 'error' : path}: ${scrub(value)}');
    }
  }

  try {
    final decoded = jsonDecode(raw);
    collect(decoded, '', 0);
    var structure = decoded is List
        ? '数组（${decoded.length} 项）'
        : decoded.runtimeType.toString();
    if (decoded is Map) {
      final known = decoded.keys
          .map((e) => e.toString().toLowerCase())
          .where((e) => leaves.contains(e) || containers.contains(e))
          .toList();
      structure =
          '标准字段=${known.isEmpty ? '无' : known.join(', ')}；其他字段=${decoded.length - known.length} 项';
    }
    return HttpFailureDetails('JSON', structure, fields);
  } on FormatException {
    final html = RegExp(
      r'<(?:!doctype|html|head|body)\b',
      caseSensitive: false,
    ).hasMatch(raw);
    final plain = html
        ? raw
              .replaceAll(
                RegExp(
                  r'<script\b[^>]*>[\s\S]*?</script>',
                  caseSensitive: false,
                ),
                '',
              )
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
        : raw;
    // Do not publish a truncated JSON document as free text: it can contain
    // account fields unrelated to the error.
    if (raw.trimLeft().startsWith('{') || raw.trimLeft().startsWith('[')) {
      return HttpFailureDetails('JSON 解析失败或正文不完整', '未解析', []);
    }
    return HttpFailureDetails(html ? 'HTML' : '文本', '非 JSON', [
      '${html ? 'HTML 文本' : '错误文本'}: ${scrub(plain)}',
    ]);
  }
}

/// Only selected response metadata is included; headers such as cookies,
/// request IDs, ETags and Locations are intentionally never copied wholesale.
String responseFacts(
  String? Function(String) header, {
  Iterable<String> secrets = const [],
}) {
  String field(String key) {
    try {
      final value = header(key);
      return value == null ? '未提供' : redactLog(value, secrets: secrets);
    } catch (_) {
      return '未捕获（响应头格式异常）';
    }
  }

  return 'Server=${field('server')}；Content-Type=${field('content-type')}；'
      'Content-Length=${field('content-length')}；Content-Encoding=${field('content-encoding')}；'
      'Content-Range=${field('content-range')}；Accept-Ranges=${field('accept-ranges')}';
}

String requestHeaderFacts(String? Function(String) header) {
  String present(String name) => header(name)?.isNotEmpty == true ? '有' : '无';
  final range = header('range');
  final rangeFact = range == null
      ? '无'
      : RegExp(r'^bytes=\d*-\d*(?:,\s*\d*-\d*)*$').hasMatch(range)
      ? range
      : '有（非标准格式）';
  final authorization =
      header('x-emby-authorization') ?? header('authorization') ?? '';
  final userIdPresent = RegExp(
    r'(?:^|[,\s])UserId\s*=\s*"[^"\s]+"',
    caseSensitive: false,
  ).hasMatch(authorization);
  return '认证令牌头=${present('x-emby-token')}；客户端身份头=${present('x-emby-authorization')}；'
      '身份头含用户 ID=${userIdPresent ? '有' : '无'}；'
      'UA=${present('user-agent')}；Range=$rangeFact；Cookie 头=${present('cookie')}；Referer 头=${present('referer')}';
}

HttpFailureDetails recordHttpFailure(
  DiagnosticLog? log,
  String requestId,
  DiagnosticBody body, {
  Iterable<String> secrets = const [],
  LogArea area = LogArea.network,
}) {
  final details = describeHttpFailure(body.bytes, secrets: secrets);
  log?.add(
    area,
    '$requestId 错误正文：${body.bytes.length} 字节；${body.state}；'
    '格式=${details.format}；${details.structure}；读取异常=${body.failure ?? '无'}',
    level: LogLevel.error,
  );
  if (details.fields.isEmpty) {
    log?.add(area, '$requestId ${details.summary}', level: LogLevel.error);
  } else {
    for (final field in details.fields) {
      log?.add(area, '$requestId 服务端原文（已脱敏）：$field', level: LogLevel.error);
    }
  }
  return details;
}
