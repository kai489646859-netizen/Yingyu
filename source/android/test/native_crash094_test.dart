import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/process_exit.dart';

const _channel = MethodChannel('yingyu/device');
final _time = DateTime(2026, 10, 18, 10, 21, 12).millisecondsSinceEpoch;
Map<String, Object?> _trace() => {
  'status': 'available',
  'timestamp': _time,
  'signal': 6,
  'arch': 'arm64',
  'abortKind': 'assertion',
  'framesTruncated': false,
  'frames': [
    {'index': 0, 'library': 'libc.so', 'pc': 'abc', 'buildId': 'a' * 40},
    {'index': 1, 'library': 'libmpv.so', 'pc': '123456', 'buildId': 'b' * 40},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });
  Future<String> collect(Object? trace, {bool latestNative = true}) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'previousExit') {
            return {
              'supported': true,
              'timestamp': _time + 1000,
              'reason': latestNative ? 5 : 10,
              'status': latestNative ? 6 : 0,
              'pssKb': 0,
            };
          }
          if (call.method == 'nativeCrashTrace') return trace;
          throw MissingPluginException();
        });
    final log = DiagnosticLog();
    await recordPreviousExit(log);
    return log.export();
  }

  test(
    'startup export includes safe native frame offsets and matching Build IDs',
    () async {
      final text = await collect(_trace());
      expect(text, contains('库=libmpv.so'));
      expect(text, contains('相对PC=0x123456'));
      expect(text, contains('BuildID=${List.filled(5, 'b' * 8).join('.')}'));
      expect(text, contains('信号=6'));
    },
  );
  test(
    'old native crash remains identifiable after a later user-stop exit',
    () async {
      final text = await collect(_trace(), latestNative: false);
      expect(text, contains('库=libmpv.so'));
      expect(
        text,
        contains(DateTime.fromMillisecondsSinceEpoch(_time).toIso8601String()),
      );
      expect(text, contains('用户或系统请求停止'));
    },
  );
  for (final status in [
    'unavailable',
    'too_large',
    'invalid',
    'expired',
    'unsupported',
    'none',
  ]) {
    test('native trace $status preserves explicit availability', () async {
      final text = await collect({
        'status': status,
        'timestamp': _time,
        'signal': 6,
      });
      expect(text, contains('原生崩溃堆栈'));
      expect(text, isNot(contains('库=')));
    });
  }
  test(
    'unknown native fields cannot inject paths URLs or raw abort messages',
    () async {
      final trace = _trace();
      trace['abortKind'] = 'https://secret.invalid/token';
      trace['frames'] = [
        {
          'index': 0,
          'library': '/private/credential',
          'pc': 'URL_SECRET',
          'buildId': 'TOKEN_SECRET',
        },
        {
          'index': 1,
          'library': 'libmpv.so',
          'pc': '1234',
          'buildId': 'a' * 40,
          'function': 'RAW_SECRET',
          'memory': 'COOKIE_SECRET',
        },
      ];
      final text = await collect(trace);
      for (final secret in [
        'secret.invalid',
        '/private',
        'URL_SECRET',
        'TOKEN_SECRET',
        'RAW_SECRET',
        'COOKIE_SECRET',
      ]) {
        expect(text, isNot(contains(secret)));
      }
      expect(text, contains('库=libmpv.so'));
    },
  );
  test('only bounded valid native frames enter exported log', () async {
    final trace = _trace();
    trace['frames'] = List.generate(
      300,
      (i) => {
        'index': i,
        'library': 'libmpv.so',
        'pc': i.toRadixString(16),
        'buildId': 'c' * 40,
      },
    );
    final text = await collect(trace);
    expect(RegExp('库=libmpv.so').allMatches(text).length, 64);
  });
  test(
    'a failed platform diagnostic never exports the platform exception',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            throw PlatformException(code: 'SYNTHETIC', message: 'RAW_SECRET');
          });
      final log = DiagnosticLog();
      await recordPreviousExit(log);
      expect(log.export(), contains('系统进程退出原因读取失败'));
      expect(log.export(), contains('应用继续运行'));
      expect(log.export(), isNot(contains('RAW_SECRET')));
    },
  );
  test('disabled logs do not request native tombstones', () async {
    var traceRequests = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          if (call.method == 'previousExit') return {'supported': false};
          traceRequests++;
          return _trace();
        });
    final log = DiagnosticLog();
    await log.setEnabled(false);
    await recordPreviousExit(log);
    expect(traceRequests, 0);
    expect(log.entries, isEmpty);
  });
  testWidgets(
    'a delayed system trace has a bounded wait independent of playback',
    (tester) async {
      final reply = Completer<Object?>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'previousExit') return {'supported': false};
            return reply.future;
          });
      final log = DiagnosticLog();
      final done = recordPreviousExit(log);
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      await done;
      expect(log.export(), contains('等待后台诊断超时'));
      reply.complete(_trace());
      await tester.pump();
      expect(log.export(), isNot(contains('库=libmpv.so')));
    },
  );
}
