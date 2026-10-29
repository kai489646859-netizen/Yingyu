import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/log_export.dart';
import 'package:yingyu/ui/logs.dart';
import 'package:yingyu/ui/style.dart';
import 'offline_capture.dart';
import 'scroll_affordance_test.dart' show fonts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '5000 mixed Unicode records split without loss, duplication or oversized IPC',
    () async {
      final log = DiagnosticLog();
      for (var i = 0; i < 5000; i++) {
        log.add(LogArea.player, '$i ${'测试😀加载进度' * 20}');
      }
      final snapshot = LogExportSnapshot(log);
      final parts = snapshot.parts;
      log.add(LogArea.player, 'new record after snapshot');
      expect(snapshot.lines.length, 5000);
      expect(parts.length, greaterThan(1));
      final records = <String>[];
      for (var i = 0; i < parts.length; i++) {
        expect(
          utf8.encode(parts[i]).length,
          lessThanOrEqualTo(LogExportSnapshot.clipboardBytes),
        );
        expect(parts[i], contains('第 ${i + 1}/${parts.length} 段'));
        records.addAll(
          parts[i]
              .split('\n')
              .where((s) => RegExp(r'^\d{4}-\d\d-\d\dT').hasMatch(s)),
        );
      }
      expect(records, snapshot.lines);
      expect(snapshot.text, isNot(contains('new record after snapshot')));
      final selection = log.entries.take(2).toSet();
      final small = LogExportSnapshot(log, selection: selection);
      expect(small.parts, [small.text]);
      expect(small.lines, selection.toList().reversed.map((e) => e.line));
      await log.flush();
      log.dispose();
    },
  );
  for (final outcome in ['saved', 'cancelled', 'failed']) {
    test(
      'file export $outcome sends only a path/name and always cleans up',
      () async {
        final dir = await Directory.systemTemp.createTemp('yingyu-log-test-');
        final file = File('${dir.path}/synthetic.txt');
        final log = DiagnosticLog();
        log.protect(['synthetic-secret']);
        for (var i = 0; i < 5000; i++) {
          log.add(LogArea.player, 'entry $i synthetic-secret');
        }
        final snapshot = LogExportSnapshot(log);
        final calls = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(LogFileExport.channel, (call) async {
          calls.add(call.method);
          expect(
            utf8.encode(jsonEncode(call.arguments)).length,
            lessThan(1024),
          );
          if (call.method == 'prepare') return file.path;
          if (call.method == 'save') {
            expect(await file.readAsString(), snapshot.text);
            expect(
              await file.readAsString(),
              isNot(contains('synthetic-secret')),
            );
            expect(call.arguments, snapshot.fileName);
            if (outcome == 'failed') {
              throw PlatformException(code: 'synthetic-write');
            }
            return outcome == 'saved';
          }
          if (call.method == 'discard') await file.delete();
          return null;
        });
        try {
          if (outcome == 'failed') {
            await expectLater(
              LogFileExport.save(snapshot),
              throwsA(isA<PlatformException>()),
            );
          } else {
            expect(await LogFileExport.save(snapshot), outcome == 'saved');
          }
          expect(calls, ['prepare', 'save', 'discard']);
          expect(await file.exists(), isFalse);
        } finally {
          messenger.setMockMethodCallHandler(LogFileExport.channel, null);
          await log.flush();
          log.dispose();
          await dir.delete();
        }
      },
    );
  }
  testWidgets(
    'large copy offers stable parts, supports retry and never silently truncates',
    (tester) async {
      final log = DiagnosticLog();
      for (var i = 0; i < 160; i++) {
        log.add(LogArea.player, 'record $i ${'完整诊断资料' * 80}');
      }
      await log.flush();
      final copied = <String>[];
      var fail = true;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (fail) throw PlatformException(code: 'synthetic-clipboard');
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      await tester.pumpWidget(MaterialApp(home: LogsPage(log: log)));
      await tester.ensureVisible(find.text('复制最新日志'));
      await tester.tap(find.text('复制最新日志'));
      await tester.pumpAndSettle();
      expect(find.text('日志较多，分段复制'), findsOneWidget);
      await tester.tap(find.text('复制第 1 段'));
      await tester.pumpAndSettle();
      expect(find.textContaining('复制失败'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('复制第 1 段'));
      await tester.pumpAndSettle();
      log.add(LogArea.player, 'arrived while copying');
      await tester.tap(find.text('下一段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制第 2 段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上一段'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制第 1 段'));
      await tester.pumpAndSettle();
      expect(copied[0], copied[2]);
      expect(copied.join(), isNot(contains('arrived while copying')));
      expect(
        copied.every(
          (p) => utf8.encode(p).length <= LogExportSnapshot.clipboardBytes,
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await log.flush();
      log.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    },
  );
  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    for (final mode in [Brightness.light, Brightness.dark]) {
      testWidgets('large log copy dialog fits $size $mode', (tester) async {
        await fonts();
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final log = DiagnosticLog();
        for (var i = 0; i < 60; i++) {
          log.add(LogArea.player, '诊断 $i ${'正在加载视频资料' * 90}');
        }
        await log.flush();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: appTheme(mode),
              home: LogsPage(log: log),
            ),
          ),
        );
        await tester.ensureVisible(find.text('复制最新日志'));
        await tester.tap(find.text('复制最新日志'));
        await tester.pumpAndSettle();
        expect(find.text('保存完整文件'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureOffline(
          tester,
          boundary,
          'log-parts-${size.width.round()}-${mode.name}',
        );
        await tester.pumpWidget(const SizedBox());
        await log.flush();
        log.dispose();
      });
    }
  }
}
