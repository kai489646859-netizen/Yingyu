import 'package:flutter/cupertino.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/playback/http_trace.dart';
import 'package:yingyu/ui/logs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'log persists a bounded redacted history and clears queued writes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final log = DiagnosticLog(prefs: prefs);
      for (var i = 0; i < DiagnosticLog.limit + 50; i++) {
        log.add(LogArea.player, 'event $i');
      }
      log.add(
        LogArea.network,
        'HTTP 403 https://example.invalid/?token=SECRET\nCookie: SECRET_COOKIE\napi_key=PRIVATE',
      );
      await log.flush();
      final restored = DiagnosticLog(prefs: prefs);
      expect(DiagnosticLog.limit, 30000);
      expect(restored.entries.length, inInclusiveRange(29000, 30000));
      expect(restored.entries.first.message, isNot('event 0'));
      expect(restored.entries.last.message, startsWith('HTTP 403'));
      expect(restored.export(), contains('HTTP 403'));
      expect(restored.export(), isNot(contains('SECRET')));
      expect(restored.export(), isNot(contains('PRIVATE')));
      expect(
        prefs.getStringList(DiagnosticLog.entriesKey)!.join(),
        isNot(contains('example.invalid')),
      );
      log.add(LogArea.app, 'pending');
      final writing = log.flush();
      await log.clear();
      await writing;
      expect(prefs.getStringList(DiagnosticLog.entriesKey), isEmpty);
      await log.setEnabled(false);
      log.add(LogArea.player, 'disabled');
      expect(log.entries, isEmpty);
      final disabled = DiagnosticLog(prefs: prefs);
      expect(disabled.enabled, false);
      log.dispose();
      restored.dispose();
      disabled.dispose();
    },
  );
  test(
    'one-click export puts fresh records before history even if a paste is truncated',
    () async {
      SharedPreferences.setMockInitialValues({
        DiagnosticLog.entriesKey: List.generate(
          350,
          (i) => LogEntry(
            DateTime.utc(2026, 10, 5).add(Duration(seconds: i)),
            '0.0.3',
            LogArea.player,
            LogLevel.info,
            '历史记录 $i ${List.filled(100, 'x').join()}',
          ).encode(),
        ),
      });
      final log = DiagnosticLog(prefs: await SharedPreferences.getInstance());
      log.add(LogArea.player, '本次原盘开始');
      log.add(LogArea.player, '本次原盘失败', level: LogLevel.error);
      final exported = log.export();
      expect(exported.length, greaterThan(30000));
      expect(exported.substring(0, 30000), contains('本次原盘失败'));
      expect(exported.indexOf('本次原盘失败'), lessThan(exported.indexOf('本次原盘开始')));
      expect(exported.indexOf('本次原盘开始'), lessThan(exported.indexOf('历史记录')));
      expect(log.entries.first.message, startsWith('历史记录 0 '));
      expect(exported, contains('最新记录在前'));
      await log.flush();
      log.dispose();
    },
  );
  test(
    'selected export is redacted, ordered and limited to retained entries',
    () async {
      final log = DiagnosticLog();
      log.add(LogArea.player, '所选较早记录');
      final older = log.entries.last;
      log.add(LogArea.player, '未选记录');
      log.add(LogArea.network, '所选最新记录 https://private.invalid/?token=PRIVATE');
      final newer = log.entries.last;
      final selected = {older, newer};
      final text = log.export(selection: selected);
      expect(text, contains('共 2 条'));
      expect(text, isNot(contains('未选记录')));
      expect(text, isNot(contains('PRIVATE')));
      expect(text, isNot(contains('private.invalid')));
      expect(text.indexOf('所选最新记录'), lessThan(text.indexOf('所选较早记录')));
      for (var i = 0; i < DiagnosticLog.limit; i++) {
        log.add(LogArea.app, '更新 $i');
      }
      expect(log.export(selection: selected), contains('共 0 条'));
      await log.flush();
      log.dispose();
    },
  );
  test(
    'native trace attributes 403 after redirect and records no request values',
    () async {
      final log = DiagnosticLog();
      final trace = HttpPlaybackTrace(
        log: log,
        address:
            'https://emby.invalid/emby/Videos/PRIVATE/stream?api_key=SECRET&sign=a%2fb',
        serverBase: Uri.parse('https://emby.invalid/emby'),
        headers: {'User-Agent': 'UA/SYNTHETIC', 'Cookie': 'SECRET_COOKIE'},
      );
      for (final line in [
        'http: request: GET /emby/Videos/PRIVATE/stream?api_key=SECRET&sign=a%2fb HTTP/1.1',
        'User-Agent: UA/SYNTHETIC',
        'Host: emby.invalid',
        'Range: bytes=0-',
        "http: header='HTTP/1.1 302 Found'",
        "http: header='Location: https://cloud.invalid/file?sign=b%2fc'",
        'http: request: GET /file?sign=b%2fc HTTP/1.1\r\nUser-Agent: UA/SYNTHETIC\r\nHost: cloud.invalid\r\nCookie: SECRET_COOKIE\r\n',
        "http: header='HTTP/1.1 403 Forbidden'",
        'http: request: GET /emby/Videos/PRIVATE/stream?api_key=SECRET&sign=a%2fb HTTP/1.1\nUser-Agent: UA/SYNTHETIC\nHost: emby.invalid\nRange: bytes=1000-',
        "http: header='HTTP/1.1 302 Found'",
      ]) {
        trace.add('ffmpeg', line);
      }
      trace.finish();
      final text = log.export();
      expect(text, contains('请求 #1：GET；目标=Emby 同源；地址原样=是；UA=一致'));
      expect(text, contains('请求 #2：GET；目标=跳转后的媒体服务'));
      expect(text, contains('响应 #2：HTTP 403；目标=跳转后的媒体服务'));
      expect(text, contains('请求 #3：GET；目标=Emby 同源；地址原样=是；UA=一致'));
      for (final secret in [
        'SECRET',
        'PRIVATE',
        'SYNTHETIC',
        'invalid',
        '%2f',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      await log.flush();
      log.dispose();
    },
  );
  test(
    'trace bounds traffic, ignores unrelated native data and spots changed UA',
    () async {
      final log = DiagnosticLog();
      final trace = HttpPlaybackTrace(
        log: log,
        address: 'https://a.invalid/v?x=%41',
        headers: {'User-Agent': 'expected'},
      );
      trace.add('vd', 'SECRET NATIVE TEXT');
      trace.add(
        'ffmpeg',
        'http: request: GET /v?x=A HTTP/1.1\nHost: a.invalid\nUser-Agent: wrong',
      );
      trace.add('ffmpeg', "http: header='HTTP/1.1 403 Forbidden'");
      for (var i = 0; i < 1000; i++) {
        trace.add('ffmpeg', "http: header='HTTP/1.1 403 Forbidden'");
      }
      trace.finish();
      expect(log.entries.length, lessThanOrEqualTo(600));
      expect(log.export(), contains('地址原样=否；UA=不一致'));
      expect(log.export(), isNot(contains('SECRET')));
      await log.flush();
      log.dispose();
    },
  );
  testWidgets('logs can filter, copy the full redacted history and clear it', (
    tester,
  ) async {
    final log = DiagnosticLog();
    log.add(LogArea.player, '播放开始');
    log.add(LogArea.network, 'HTTP 403', level: LogLevel.error);
    await log.flush();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      log.dispose();
    });
    await tester.pumpWidget(MaterialApp(home: LogsPage(log: log)));
    expect(find.text('播放开始'), findsOneWidget);
    await tester.ensureVisible(find.byType(CupertinoSwitch).last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CupertinoSwitch).last);
    await tester.pumpAndSettle();
    expect(find.text('播放开始'), findsNothing);
    expect(find.text('HTTP 403'), findsOneWidget);
    await tester.ensureVisible(find.text('复制最新日志'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制最新日志'));
    await tester.pumpAndSettle();
    expect(copied, contains('播放开始'));
    expect(copied, contains('HTTP 403'));
    expect(copied!.indexOf('HTTP 403'), lessThan(copied!.indexOf('播放开始')));
    await tester.ensureVisible(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(log.entries, isNotEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(log.entries, isNotEmpty);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    final retained = log.entries.length;
    expect(retained, greaterThan(0));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(log.entries.length, retained);
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认清空'));
    await tester.pumpAndSettle();
    expect(find.text('暂无日志'), findsOneWidget);
    expect(log.entries, isEmpty);
  });
  testWidgets(
    'logs support multi-select, filtered selection, copying and clearing',
    (tester) async {
      final log = DiagnosticLog();
      log.add(LogArea.player, '较早信息');
      log.add(LogArea.player, '中间警告', level: LogLevel.warning);
      log.add(LogArea.network, '最新错误', level: LogLevel.error);
      await log.flush();
      final rows = log.entries;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        log.dispose();
      });
      await tester.pumpWidget(MaterialApp(home: LogsPage(log: log)));
      await tester.ensureVisible(find.text('选择日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择日志'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CupertinoButton>(
              find.widgetWithText(CupertinoButton, '复制所选（0）'),
            )
            .onPressed,
        null,
      );
      await tester.ensureVisible(find.byKey(ValueKey(rows.first)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(rows.first)));
      await tester.ensureVisible(find.byKey(ValueKey(rows.last)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(rows.last)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('复制所选（2）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制所选（2）'));
      await tester.pumpAndSettle();
      expect(copied, contains('较早信息'));
      expect(copied, contains('最新错误'));
      expect(copied, isNot(contains('中间警告')));
      expect(copied!.indexOf('最新错误'), lessThan(copied!.indexOf('较早信息')));
      await tester.ensureVisible(find.text('取消选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消选择'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(CupertinoSwitch).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CupertinoSwitch).last);
      await tester.ensureVisible(find.text('选择日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择日志'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('全选当前列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选当前列表'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('复制所选（2）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制所选（2）'));
      await tester.pumpAndSettle();
      expect(copied, contains('中间警告'));
      expect(copied, contains('最新错误'));
      expect(copied, isNot(contains('较早信息')));
      await tester.ensureVisible(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清空'));
      await tester.pumpAndSettle();
      expect(find.text('复制所选（0）'), findsOneWidget);
      expect(tester.takeException(), null);
    },
  );
  for (final size in [const Size(390, 800), const Size(800, 360)]) {
    testWidgets('log selection fits $size with larger text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final log = DiagnosticLog()..add(LogArea.player, '合成日志条目');
      await log.flush();
      addTearDown(log.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: LogsPage(log: log),
        ),
      );
      await tester.ensureVisible(find.text('选择日志'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择日志'));
      await tester.pumpAndSettle();
      expect(find.text('复制所选（0）'), findsOneWidget);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    });
  }
  test('malformed persisted records do not prevent opening settings', () async {
    SharedPreferences.setMockInitialValues({
      DiagnosticLog.entriesKey: [
        'not json',
        jsonEncode({'message': 'SECRET'}),
      ],
    });
    final log = DiagnosticLog(prefs: await SharedPreferences.getInstance());
    expect(log.entries, isEmpty);
    log.dispose();
  });

  test(
    'storage capacity preserves more than 5000 historical entries',
    () async {
      SharedPreferences.setMockInitialValues({
        DiagnosticLog.entriesKey: List.generate(
          600,
          (i) => LogEntry(
            DateTime.utc(2026, 10, 8).add(Duration(seconds: i)),
            '0.2.9',
            LogArea.player,
            LogLevel.info,
            '旧版本 $i',
          ).encode(),
        ),
      });
      final prefs = await SharedPreferences.getInstance();
      final log = DiagnosticLog(prefs: prefs);
      expect(log.entries, hasLength(600));
      for (var i = 0; i < 4405; i++) {
        log.add(LogArea.player, '新记录 $i');
      }
      await log.flush();
      final restored = DiagnosticLog(prefs: prefs);
      expect(restored.entries, hasLength(5005));
      expect(restored.entries.first.message, '旧版本 0');
      expect(restored.entries.first.version, '0.2.9');
      expect(restored.export(), contains('8 MiB'));
      expect(restored.export(), contains('共 5005 条'));
      expect(
        restored.export().indexOf('新记录 4404'),
        lessThan(restored.export().indexOf('旧版本 599')),
      );
      log.dispose();
      restored.dispose();
    },
  );
}
