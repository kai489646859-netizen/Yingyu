import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/anr_trace.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yingyu/device');
  final report = <String, Object>{
    'status': 'available',
    'timestamp': 1792352100000,
    'traceTimestamp': 1792422000000,
    'tracePid': 42,
    'association': 'time-mismatch',
    'threads': [
      {
        'id': 1,
        'role': 'main',
        'state': 'Native',
        'frames': [
          {
            'kind': 'java',
            'method':
                'io.flutter.embedding.engine.FlutterJNI.nativeSurfaceDestroyed',
          },
        ],
      },
    ],
  };
  setUp(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => report,
    ),
  );
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );
  test('same trace imported twice only retains one complete stack', () async {
    final log = DiagnosticLog();
    await recordAnrTrace(log);
    await recordAnrTrace(log);
    expect('Java='.allMatches(log.export()).length, 1);
    expect(log.export(), contains('堆栈晚于退出事件'));
    expect(log.export(), contains('补录时间不等于发生时间'));
    await log.flush();
    log.dispose();
  });
  test(
    'history dedup survives journal reload without removing new failures',
    () async {
      final first = DiagnosticLog();
      await recordAnrTrace(first);
      final log = DiagnosticLog(restored: first.entries);
      await recordAnrTrace(log);
      expect('Java='.allMatches(log.export()).length, 1);
      final changed = Map.of(report)..['traceTimestamp'] = 1792422060000;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => changed,
      );
      await recordAnrTrace(log);
      expect('Java='.allMatches(log.export()).length, 2);
      await first.flush();
      await log.flush();
      first.dispose();
      log.dispose();
    },
  );
  test(
    'clearing history allows a retained system trace to be imported again',
    () async {
      final log = DiagnosticLog();
      await recordAnrTrace(log);
      await log.clear();
      await recordAnrTrace(log);
      expect('Java='.allMatches(log.export()).length, 1);
      await log.flush();
      log.dispose();
    },
  );
}
