import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
// Public path API already pinned by the existing image-cache dependency.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../version.dart';
import 'log_storage.dart';
import 'log_policy.dart';
export 'log_policy.dart';

List<LogEntry> _decodeLogHistory(List<String> lines) =>
    lines.map(LogEntry.decode).whereType<LogEntry>().toList();

enum LogArea {
  app('软件运行'),
  api('Emby 接口'),
  route('播放路线'),
  network('媒体网络'),
  player('播放核心'),
  progress('进度同步');

  const LogArea(this.label);
  final String label;
}

enum LogLevel {
  info('信息'),
  warning('警告'),
  error('错误');

  const LogLevel(this.label);
  final String label;
}

/// Defence in depth for fixed facts and bounded server error fields. Raw native
/// messages, successful API bodies and credential values are never exported.
String redactLog(String value, {Iterable<String> secrets = const []}) {
  var text = value;
  final protected = secrets.where((s) => s.isNotEmpty).toSet().toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final secret in protected) {
    for (final spelling in {
      secret,
      Uri.encodeComponent(secret),
      Uri.encodeQueryComponent(secret),
      Uri.encodeComponent(
        secret,
      ).replaceAllMapped(RegExp(r'%[0-9A-F]{2}'), (m) => m[0]!.toLowerCase()),
      Uri.encodeQueryComponent(
        secret,
      ).replaceAllMapped(RegExp(r'%[0-9A-F]{2}'), (m) => m[0]!.toLowerCase()),
    }) {
      text = text.replaceAll(spelling, '[敏感值已隐藏]');
    }
  }
  text = text.replaceAll(
    RegExp(
      r'\b(?:https?|rtsp|ftp|smb|file)://[^\s<>"\x27]+',
      caseSensitive: false,
    ),
    '[地址已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'''["'](?:api[_-]?key|access[_-]?token|token|password|passwd|username|userId|deviceId|playSessionId|sign|signature|pickcode|pw)["']\s*:\s*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')''',
      caseSensitive: false,
    ),
    '[敏感字段已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'(?:authorization|proxy-authorization|cookie|set-cookie|x-emby-authorization|x-emby-token)\s*[:=][^\r\n]*',
      caseSensitive: false,
    ),
    '[认证头已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'(?:api[_-]?key|access[_-]?token|token|password|passwd|username|userId|deviceId|playSessionId|sign|signature|pickcode|pw)\s*[=:]\s*[^\s&;,]+',
      caseSensitive: false,
    ),
    '[敏感参数已隐藏]',
  );
  text = text.replaceAll(
    RegExp(r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b'),
    '[IP 已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'''(?:Failed host lookup:\s*['"])[^'"\r\n]+['"]''',
      caseSensitive: false,
    ),
    'Failed host lookup: [主机已隐藏]',
  );
  text = text.replaceAll(
    RegExp(r'\baddress\s*=\s*[^\s,;()\[\]]+', caseSensitive: false),
    'address=[主机已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'(?<![\w:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?![\w:])',
      caseSensitive: false,
    ),
    '[IP 已隐藏]',
  );
  text = text.replaceAll(
    RegExp(r'\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', caseSensitive: false),
    '[邮箱已隐藏]',
  );
  text = text.replaceAll(
    RegExp(r'''\b[A-Za-z]:[\\/][^\r\n<>"']+'''),
    '[路径已隐藏]',
  );
  text = text.replaceAll(
    RegExp(r'''(?<![\w:])/(?:[^/\s<>"']+/)+[^\s<>"']*'''),
    '[路径已隐藏]',
  );
  text = text.replaceAll(
    RegExp(
      r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b|\b[0-9a-f]{24,}\b',
      caseSensitive: false,
    ),
    '[标识已隐藏]',
  );
  text = text.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
  return text.length > 1200 ? '${text.substring(0, 1200)}…[文本已截断]' : text;
}

class LogEntry {
  LogEntry(
    this.time,
    this.version,
    this.area,
    this.level,
    String message, {
    int? buildCode,
  }) : buildCode = buildCode != null && buildCode > 0 && buildCode <= 2147483647
           ? buildCode
           : null,
       message = redactLog(message);
  final DateTime time;
  final String version;
  final int? buildCode;
  final LogArea area;
  final LogLevel level;
  final String message;
  String get line =>
      '${time.toLocal().toIso8601String()} [$version${buildCode == null ? '' : '/code$buildCode'}] '
      '[${level.label}] [${area.label}] $message';
  // Entries are immutable. Encode only once instead of re-encoding up to
  // historical entries at every diagnostic persistence tick.
  late final String _encoded = jsonEncode({
    'time': time.toIso8601String(),
    'version': version,
    if (buildCode != null) 'buildCode': buildCode,
    'area': area.name,
    'level': level.name,
    'message': message,
  });
  String encode() => _encoded;
  late final int storedBytes = utf8.encode(_encoded).length + 1;
  static LogEntry? decode(String raw) {
    try {
      if (raw.length > 6000) return null;
      final data = jsonDecode(raw) as Map;
      final version = data['version'] as String;
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) return null;
      return LogEntry(
        DateTime.parse(data['time'] as String),
        version,
        LogArea.values.byName(data['area'] as String),
        LogLevel.values.byName(data['level'] as String),
        data['message'] as String,
        buildCode: data['buildCode'] is int ? data['buildCode'] as int : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class DiagnosticLog extends ChangeNotifier {
  DiagnosticLog({
    this.prefs,
    this.console = false,
    this.storage,
    List<LogEntry>? restored,
  }) {
    enabled = prefs?.getBool(enabledKey) ?? true;
    if (restored != null) {
      _entries.addAll(restored);
    } else {
      for (final value
          in (prefs?.getStringList(entriesKey) ?? <String>[]).reversed
              .take(limit)
              .toList()
              .reversed) {
        final entry = LogEntry.decode(value);
        if (entry != null) _entries.add(entry);
      }
    }
    _storedBytes = _entries.fold(0, (sum, entry) => sum + entry.storedBytes);
    _trim();
  }

  static Future<DiagnosticLog> open(
    SharedPreferences prefs, {
    bool console = false,
    LogFileStorage? storage,
  }) async {
    try {
      final journal =
          storage ??
          LogFileStorage(
            File(
              '${(await getApplicationSupportDirectory()).path}/diagnostics-v2.jsonl',
            ),
          );
      final saved = await journal.read();
      final source = saved ?? (prefs.getStringList(entriesKey) ?? <String>[]);
      final entries = await compute(
        _decodeLogHistory,
        source.skip((source.length - limit).clamp(0, source.length)).toList(),
      );
      final log = DiagnosticLog(
        prefs: prefs,
        console: console,
        storage: journal,
        restored: entries,
      );
      if (saved == null ||
          journal.rows > limit * 2 ||
          journal.storedBytes > logStorageBytes ||
          log._entries.length != entries.length) {
        await journal.replace(log._entries.map((e) => e.encode()).toList());
      }
      // Commit the journal before removing the legacy, multi-megabyte value.
      // Other preference writes no longer have to rewrite that old log blob.
      try {
        if (prefs.containsKey(entriesKey) && !await prefs.remove(entriesKey)) {
          throw StateError('legacy cleanup');
        }
      } catch (_) {
        log.storageError = '旧日志存储迁移清理失败，日志已保留';
      }
      return log;
    } catch (_) {
      return DiagnosticLog(prefs: prefs, console: console)
        ..storageError = '独立日志文件暂不可用，原日志已保留';
    }
  }

  static const entriesKey = 'yingyu.logs.v1';
  static const enabledKey = 'yingyu.logs.enabled.v1';
  static const limit = logStorageEntries;
  final SharedPreferences? prefs;
  final bool console;
  final LogFileStorage? storage;
  final _entries = <LogEntry>[];
  int _storedBytes = 0;
  int get storedBytes => _storedBytes;
  void _trim() {
    if (_entries.length <= limit && _storedBytes <= logStorageBytes) return;
    final targetBytes = _storedBytes > logStorageBytes
        ? logCompactBytes
        : logStorageBytes;
    final targetCount = _entries.length > limit ? limit - 1000 : limit;
    var remove = 0;
    while (remove < _entries.length &&
        (_entries.length - remove > targetCount ||
            _storedBytes > targetBytes)) {
      _storedBytes -= _entries[remove++].storedBytes;
    }
    _entries.removeRange(0, remove);
    _pendingRecords.clear();
    _replacePending = true;
  }

  final _pendingRecords = <LogEntry>[];
  bool _replacePending = false;
  List<LogEntry> get entries => List.unmodifiable(_entries);
  late bool enabled;
  String? storageError;
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  bool _disposed = false;
  int _sequence = 0;
  String nextRequest(String prefix) => '$prefix${++_sequence}';
  final _secrets = <String>{};
  void protect(Iterable<String> values) {
    _secrets.addAll(values.where((s) => s.length >= 3));
    while (_secrets.length > 256) {
      _secrets.remove(_secrets.first);
    }
  }

  String sanitize(String value) => redactLog(value, secrets: _secrets);

  void add(LogArea area, String message, {LogLevel level = LogLevel.info}) {
    if (!enabled || _disposed) return;
    final entry = LogEntry(
      DateTime.now(),
      appVersion,
      area,
      level,
      sanitize(message),
      buildCode: androidVersionCode,
    );
    _entries.add(entry);
    _storedBytes += entry.storedBytes;
    if (!_replacePending) _pendingRecords.add(entry);
    _trim();
    // Only the already-redacted structured record is sent to Android logcat.
    if (console || level == LogLevel.error) {
      debugPrintSynchronously('YINGYU_DIAG ${entry.encode()}');
    }
    notifyListeners();
    if (level == LogLevel.error) {
      _saveTimer?.cancel();
      _saveTimer = null;
    }
    _saveTimer ??= Timer(
      level == LogLevel.error ? Duration.zero : const Duration(milliseconds: 250),
      () {
        _saveTimer = null;
        unawaited(flush());
      },
    );
  }

  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    // Reuse the current save instead of queuing an empty write callback.
    if (_pendingRecords.isEmpty && !_replacePending) return _writes;
    _writes = _writes.then((_) async {
      if (_pendingRecords.isEmpty && !_replacePending) return;
      final pending = List<LogEntry>.of(_pendingRecords);
      final replace = _replacePending;
      _pendingRecords.clear();
      _replacePending = false;
      final previousError = storageError;
      List<String> snapshot() => _entries.map((e) => e.encode()).toList();
      try {
        if (storage != null) {
          if (replace) {
            await storage!.replace(snapshot());
          } else {
            await storage!.append(
              pending.map((e) => e.encode()).toList(),
              snapshot,
            );
          }
        } else if (prefs != null &&
            !await prefs!.setStringList(entriesKey, snapshot())) {
          throw StateError('save');
        }
        storageError = null;
      } catch (_) {
        // An append can fail after a partial write. The next save atomically
        // replaces it with current memory, never re-appends duplicate rows.
        _replacePending = true;
        storageError = '日志未能保存到本机，当前记录仍可复制';
      }
      if (!_disposed && storageError != previousError) notifyListeners();
    });
    return _writes;
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    notifyListeners();
    await flush();
    try {
      if (prefs != null && !await prefs!.setBool(enabledKey, value)) {
        throw StateError('save');
      }
    } catch (_) {
      storageError = '日志开关未能保存，重启后可能恢复';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> clear() {
    _entries.clear();
    _storedBytes = 0;
    _pendingRecords.clear();
    _replacePending = true;
    notifyListeners();
    return flush();
  }

  String export({Set<LogEntry>? selection}) {
    final records = _entries.reversed
        .where((entry) => selection == null || selection.contains(entry))
        .toList();
    return '映屿安卓 $appVersion · 构建 $diagnosticBuild · 本机脱敏日志\n'
        '导出时间：${DateTime.now().toIso8601String()}\n'
        '导出范围：${selection == null ? '最近保留的日志' : '手动选择的日志'}，共 ${records.length} 条；顺序：最新记录在前。\n'
        '$logRetentionDescription；未记录账户、Cookie 或完整片源地址。\n\n'
        '${records.map((e) => e.line).join('\n')}\n';
  }

  @override
  void dispose() {
    unawaited(flush());
    _disposed = true;
    super.dispose();
  }
}
