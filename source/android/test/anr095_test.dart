import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/process_exit.dart';
import 'package:yingyu/core/anr_trace.dart';

const channel = MethodChannel('yingyu/device');
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
  Future<String> collect(Object? value) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => value);
    final log = DiagnosticLog();
    await recordAnrTrace(log);
    return log.export();
  }

  for (final status in [
    'none',
    'unavailable',
    'invalid',
    'unsupported',
    'expired',
    'too_large',
  ]) {
    test('ANR $status is explicit and does not invent frames', () async {
      final text = await collect({'status': status});
      expect(text, contains('应用无响应堆栈'));
      expect(text, isNot(contains('Java=')));
      expect(text, isNot(contains('库=')));
    });
  }
  test('ANR export rejects untrusted trace strings', () async {
    final text = await collect({
      'status': 'available',
      'timestamp': 1,
      'threads': [
        {
          'id': 1,
          'role': 'https://secret.invalid',
          'state': 'SECRET',
          'frames': [
            {'kind': 'java', 'method': 'https://secret.invalid/token'},
            {'kind': 'native', 'pc': 'SECRET', 'library': '/private/secret'},
            {
              'kind': 'java',
              'method': 'android.os.MessageQueue.nativePollOnce',
            },
          ],
        },
      ],
    });
    expect(text, contains('MessageQueue.nativePollOnce'));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('SECRET')));
  });
  test('ANR export applies total frame and per-thread bounds', () async {
    final text = await collect({
      'status': 'available',
      'timestamp': 1,
      'threads': [
        for (var i = 0; i < 90; i++)
          {
            'id': i,
            'frames': [
              for (var j = 0; j < 80; j++)
                {'kind': 'native', 'pc': 'abc', 'library': 'libc.so'},
            ],
          },
      ],
    });
    expect('相对PC='.allMatches(text).length, 256);
  });
  test('disabled logging does not request an ANR trace', () async {
    var requested = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          requested = true;
          return null;
        });
    await recordAnrTrace((DiagnosticLog()..enabled = false));
    expect(requested, false);
  });
  test(
    'startup exports recent ANR independently from the older native crash',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'previousExit') {
              return {
                'supported': true,
                'timestamp': 1792291908426,
                'reason': 6,
                'status': 0,
                'pssKb': 0,
              };
            }
            if (call.method == 'nativeCrashTrace') return {'status': 'none'};
            if (call.method == 'anrTrace') {
              return {
                'status': 'available',
                'timestamp': 1792291908426,
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
            }
            throw MissingPluginException();
          });
      final log = DiagnosticLog();
      await recordPreviousExit(log);
      expect(log.export(), contains('[ANR095]'));
      expect(log.export(), contains('FlutterJNI.nativeSurfaceDestroyed'));
      expect(log.export(), contains('线程=1'));
    },
  );
}
