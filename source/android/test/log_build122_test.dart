import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/log_export.dart';
import 'package:yingyu/version.dart';

List<LogEntry> reusedVersionHistory() {
  final base = DateTime.utc(2026, 10, 21);
  LogEntry entry(int index, String message, {bool error = false}) => LogEntry(
    base.add(Duration(seconds: index)),
    appVersion,
    LogArea.app,
    error ? LogLevel.error : LogLevel.info,
    message,
  );
  return [
    entry(0, '软件启动；构建=20261021-playback-old-code144；日志上限=30000 条'),
    for (var i = 1; i <= 3; i++) entry(i, '封存旧构建错误 $i', error: true),
    entry(4, '软件启动；构建=$diagnosticBuild；日志上限=30000 条'),
    entry(5, '当前正常播放'),
    entry(6, '当前增强正常'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'same display version never assigns archived errors to current build',
    () {
      final log = DiagnosticLog(restored: reusedVersionHistory());
      addTearDown(log.dispose);
      final snapshot = LogExportSnapshot(log);
      expect(
        snapshot.summary,
        contains('当前构建 $appVersion/code$androidVersionCode：3 条'),
      );
      final current = snapshot.summary
          .split('\n')
          .singleWhere((line) => line.startsWith('当前构建 '));
      expect(current, contains('错误=0 条'));
      expect(snapshot.text, contains('封存旧构建错误 3'));
      expect(snapshot.lines, hasLength(7));
    },
  );
  test(
    'selected export resolves build before filtering out startup marker',
    () {
      final log = DiagnosticLog(restored: reusedVersionHistory());
      addTearDown(log.dispose);
      final selected = {log.entries[2], log.entries[5]};
      final snapshot = LogExportSnapshot(log, selection: selected);
      expect(
        snapshot.summary,
        contains('当前构建 $appVersion/code$androidVersionCode：1 条'),
      );
      expect(snapshot.lines, hasLength(2));
      expect(snapshot.text, contains('封存旧构建错误 2'));
    },
  );
  test(
    'actual legacy startup without code does not invent an install number',
    () {
      final history = reusedVersionHistory();
      history[0] = LogEntry(
        history[0].time,
        appVersion,
        LogArea.app,
        LogLevel.info,
        '软件启动；构建=20261021-feedback121-from120；日志上限=30000 条',
      );
      final log = DiagnosticLog(restored: history);
      addTearDown(log.dispose);
      final snapshot = LogExportSnapshot(log);
      expect(snapshot.summary, contains('$appVersion/构建未提供=4 条'));
      expect(
        snapshot.summary,
        contains('当前构建 $appVersion/code$androidVersionCode：3 条'),
      );
      expect(snapshot.summary, contains('错误=0 条'));
      expect(
        snapshot.lines.where((line) => line.contains('[错误]')),
        hasLength(3),
      );
      expect(snapshot.text, isNot(contains('code144')));
    },
  );
  test(
    'new records retain build after persistence and missing startup marker',
    () async {
      final log = DiagnosticLog();
      addTearDown(log.dispose);
      log.add(LogArea.player, '真实当前错误', level: LogLevel.error);
      final saved = LogEntry.decode(log.entries.single.encode())!;
      expect(saved.buildCode, androidVersionCode);
      expect(saved.line, contains('[$appVersion/code$androidVersionCode]'));
      final restored = DiagnosticLog(restored: [saved]);
      addTearDown(restored.dispose);
      expect(LogExportSnapshot(restored).summary, contains('错误=1 条'));
      await log.flush();
    },
  );
  test(
    'legacy rows without a startup marker stay unknown and remain exported',
    () {
      final log = DiagnosticLog(restored: reusedVersionHistory().sublist(1, 4));
      addTearDown(log.dispose);
      final snapshot = LogExportSnapshot(log);
      expect(
        snapshot.summary,
        contains('当前构建 $appVersion/code$androidVersionCode：0 条'),
      );
      expect(snapshot.summary, contains('$appVersion/构建未提供=3 条'));
      expect(snapshot.lines, hasLength(3));
      expect(snapshot.text, contains('封存旧构建错误 1'));
    },
  );
  test(
    'a changed version or malformed startup never inherits earlier identity',
    () {
      final history = reusedVersionHistory();
      final base = history.last.time;
      for (final invalidates in [
        LogEntry(base, '0.0.1', LogArea.app, LogLevel.info, '其他版本'),
        LogEntry(base, appVersion, LogArea.app, LogLevel.info, '软件启动；构建=无效'),
      ]) {
        final log = DiagnosticLog(
          restored: [
            ...history,
            invalidates,
            LogEntry(
              base,
              appVersion,
              LogArea.player,
              LogLevel.error,
              '未知归属错误',
            ),
          ],
        );
        final snapshot = LogExportSnapshot(log);
        final current = snapshot.summary
            .split('\n')
            .singleWhere((row) => row.startsWith('当前构建 '));
        expect(current, contains('错误=0 条'));
        expect(snapshot.text, contains('未知归属错误'));
        log.dispose();
      }
    },
  );
  test('invalid optional build metadata never drops the historical record', () {
    final entry = reusedVersionHistory()[1];
    for (final code in [null, -1, 0, 'not-a-code', 2147483648]) {
      final raw = jsonDecode(entry.encode()) as Map<String, dynamic>;
      raw['buildCode'] = code;
      final restored = LogEntry.decode(jsonEncode(raw));
      expect(restored, isNotNull);
      expect(restored!.buildCode, isNull);
      expect(restored.message, entry.message);
    }
  });
  test(
    'many build identities do not overflow clipboard headers or lose rows',
    () {
      final log = DiagnosticLog(
        restored: [
          for (var i = 1; i <= 700; i++)
            LogEntry(
              DateTime.utc(2026).add(Duration(seconds: i)),
              appVersion,
              LogArea.player,
              LogLevel.info,
              '构建记录 $i ${'x' * 120}',
              buildCode: i,
            ),
        ],
      );
      addTearDown(log.dispose);
      final snapshot = LogExportSnapshot(log);
      expect(snapshot.summary, contains('另有668类'));
      final lines = <String>[];
      for (final part in snapshot.parts) {
        expect(
          utf8.encode(part).length,
          lessThanOrEqualTo(LogExportSnapshot.clipboardBytes),
        );
        lines.addAll(
          part
              .split('\n')
              .where((row) => RegExp(r'^\d{4}-\d\d-\d\dT').hasMatch(row)),
        );
      }
      expect(lines, snapshot.lines);
      expect(lines, hasLength(700));
    },
  );
}
