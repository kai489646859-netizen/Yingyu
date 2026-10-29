import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'log.dart';

/// Deduplicate a complete imported report, not just its exit timestamp. Some
/// systems return a different trace for an older exit record. Changing stack
/// evidence must remain visible even when that event timestamp is unchanged.
String historicalReportMarker(String kind, Map<dynamic, dynamic> report) {
  Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.whereType<String>().toList()..sort();
      return {
        for (final key in keys)
          if (key != 'currentOpenFds') key: canonical(value[key]),
      };
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  final hash = sha256
      .convert(utf8.encode(jsonEncode(canonical(report))))
      .toString();
  final grouped = [
    for (var i = 0; i < hash.length; i += 8) hash.substring(i, i + 8),
  ].join('.');
  return '[历史诊断已收录] $kind；指纹=$grouped';
}

bool historicalReportExists(DiagnosticLog log, String marker) =>
    log.entries.any((entry) => entry.message == log.sanitize(marker));

String diagnosticTime(Object? value) =>
    value is int && value > 0 && value < 4102444800000
    ? DateTime.fromMillisecondsSinceEpoch(value).toIso8601String()
    : '未提供';
