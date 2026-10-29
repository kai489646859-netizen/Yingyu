import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'log.dart';
import '../version.dart';

/// Freeze a redacted snapshot so new records cannot shift successive copies.
class LogExportSnapshot {
  LogExportSnapshot(DiagnosticLog log, {Set<LogEntry>? selection})
    : this._(log.entries, selection: selection);

  LogExportSnapshot._(List<LogEntry> entries, {Set<LogEntry>? selection})
    : time = DateTime.now(),
      selected = selection != null,
      _buildCodes = _resolveBuildCodes(entries),
      _entries = List.unmodifiable(
        entries.reversed.where(
          (e) => selection == null || selection.contains(e),
        ),
      );

  final DateTime time;
  final bool selected;
  final List<LogEntry> _entries;
  final Map<LogEntry, int?> _buildCodes;
  late final List<String> lines = List.unmodifiable(
    _entries.map((e) {
      final code = _buildCodes[e];
      return code == null || e.buildCode != null
          ? e.line
          : e.line.replaceFirst('[${e.version}]', '[${e.version}/code$code]');
    }),
  );
  late final String summary = () {
    final versions = <String, int>{};
    final builds = <String, int>{};
    for (final entry in _entries) {
      versions.update(entry.version, (n) => n + 1, ifAbsent: () => 1);
      final code = _buildCodes[entry];
      final build = '${entry.version}/${code == null ? '构建未提供' : 'code$code'}';
      builds.update(build, (n) => n + 1, ifAbsent: () => 1);
    }
    final current = _entries
        .where(
          (e) =>
              e.version == appVersion && _buildCodes[e] == androidVersionCode,
        )
        .toList();
    return '显示版本分布：${_distribution(versions)}。\n'
        '构建分布：${_distribution(builds)}。\n'
        '当前构建 $appVersion/code$androidVersionCode：${current.length} 条'
        '${current.isEmpty ? '' : '；时间范围=${current.last.time.toLocal().toIso8601String()} 至 ${current.first.time.toLocal().toIso8601String()}；错误=${current.where((e) => e.level == LogLevel.error).length} 条；警告=${current.where((e) => e.level == LogLevel.warning).length} 条'}。\n'
        '错误条数不等于独立故障数；同一 API 编号表示同一次请求，其他构建或构建未提供的历史记录不代表当前构建仍有该故障。\n';
  }();
  static const clipboardBytes = 24 * 1024;
  String get header =>
      '映屿安卓 $appVersion · 构建 $diagnosticBuild · 本机脱敏日志\n'
      '导出时间：${time.toIso8601String()}\n'
      '导出范围：${selected ? '手动选择的日志' : '最近保留的日志'}，共 ${lines.length} 条；顺序：最新记录在前。\n'
      '$summary'
      '$logRetentionDescription；未记录账户、Cookie 或完整片源地址。\n';
  String get text => '$header\n${lines.join('\n')}\n';
  String get fileName =>
      '映屿日志-$appVersion-${time.toIso8601String().replaceAll(RegExp(r'[:.]'), '-')}.txt';

  List<String> get parts {
    if (utf8.encode(text).length <= clipboardBytes) return [text];
    final chunks = <List<String>>[];
    var current = <String>[];
    final budget = clipboardBytes - utf8.encode(header).length - 256;
    var bytes = 0;
    for (final line in lines) {
      final size = utf8.encode('$line\n').length;
      if (current.isNotEmpty && bytes + size > budget) {
        chunks.add(current);
        current = [];
        bytes = 0;
      }
      current.add(line);
      bytes += size;
    }
    if (current.isNotEmpty) chunks.add(current);
    return [
      for (var i = 0; i < chunks.length; i++)
        '$header分段：第 ${i + 1}/${chunks.length} 段，本段 ${chunks[i].length} 条。\n\n${chunks[i].join('\n')}\n',
    ];
  }
}

// Keep every record while bounding the repeated header in clipboard parts.
String _distribution(Map<String, int> counts) {
  final labels = counts.entries.take(32).map((entry) {
    final key = entry.key.length <= 48
        ? entry.key
        : '${entry.key.substring(0, 48)}…';
    return '$key=${entry.value} 条';
  }).toList();
  if (counts.length > 32) labels.add('另有${counts.length - 32}类，详见完整记录');
  return labels.join('；');
}

/// Legacy entries gain an identity only from a retained startup marker in
/// chronological storage order. Resolve before selection; unknown stays unknown.
Map<LogEntry, int?> _resolveBuildCodes(List<LogEntry> entries) {
  final builds = <LogEntry, int?>{};
  final marker = RegExp(
    r'^软件启动；构建=\d{8}-[a-z0-9-]{1,100}-code([1-9]\d{0,9})；日志上限=\d{1,6} 条$',
  );
  String? version;
  int? code;
  for (final entry in entries) {
    if (entry.version != version) {
      version = entry.version;
      code = null;
    }
    if (entry.area == LogArea.app &&
        entry.level == LogLevel.info &&
        entry.message.startsWith('软件启动；构建=')) {
      final match = marker.firstMatch(entry.message);
      final parsed = match == null ? null : int.tryParse(match[1]!);
      code = parsed != null && parsed <= 2147483647 ? parsed : null;
    }
    builds[entry] = entry.buildCode ?? code;
  }
  return Map.unmodifiable(builds);
}

class LogFileExport {
  static const channel = MethodChannel('yingyu/log-export');

  static Future<bool> save(LogExportSnapshot snapshot) async {
    // Only a small path/name crosses Binder. The full UTF-8 file is written
    // directly to the private temp file supplied by our Android bridge.
    final path = await channel.invokeMethod<String>('prepare');
    if (path == null) throw StateError('没有可写入的日志文件');
    try {
      await File(
        path,
      ).writeAsString(snapshot.text, encoding: utf8, flush: true);
      return await channel.invokeMethod<bool>('save', snapshot.fileName) ??
          false;
    } finally {
      await channel.invokeMethod<void>('discard');
    }
  }
}
