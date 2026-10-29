import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/http_diagnostics.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'core_test.dart' show syntheticSession, playbackData;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diagnostic inspection cannot reject opaque URL bytes', () async {
    const address = 'https://cloud.invalid/movie?sig=%FF%2f%41&static=true';
    final client = EmbyClient(
      client: MockClient(
        (_) async => http.Response(jsonEncode(playbackData(url: address)), 200),
      ),
    );
    client.session = syntheticSession();
    final route = await client.playback(MediaItem({'Id': 'test'}));
    expect(route.url, address);
    client.close();
    expect(
      redactLog('value SECRET%2fVALUE', secrets: ['SECRET/VALUE']),
      isNot(contains('SECRET')),
    );
    expect(
      responseFacts((_) => throw const FormatException('PRIVATE')),
      contains('未捕获'),
    );
  });

  test(
    'actual nested JSON errors survive while identities and unknown fields do not',
    () {
      final details = describeHttpFailure(
        utf8.encode(
          jsonEncode({
            'ResponseStatus': {
              'ErrorCode': 'UnfamiliarServerException',
              'Message':
                  'Emby declined device DEVICE_PRIVATE for USER_PRIVATE; reason: provider unavailable',
              'Errors': [
                {'Code': 'UPSTREAM_403', 'Message': 'Retry later'},
              ],
              'StackTrace': 'PRIVATE_STACK',
            },
            'AccessToken': 'UNLISTED_SECRET',
          }),
        ),
        secrets: ['DEVICE_PRIVATE', 'USER_PRIVATE'],
      );
      expect(details.format, 'JSON');
      expect(details.summary, contains('UnfamiliarServerException'));
      expect(details.summary, contains('provider unavailable'));
      expect(details.summary, contains('UPSTREAM_403'));
      expect(details.summary, isNot(contains('PRIVATE')));
      expect(details.summary, isNot(contains('UNLISTED_SECRET')));
      expect(details.summary, isNot(contains('订阅或许可证')));
    },
  );

  test('details arrays and plain text are redacted before export', () {
    final body = jsonEncode({
      'detail': [
        'denied https://private.invalid/a?token=secret',
        r'failed at C:\Users\PRIVATE\file.mkv',
        'user a@private.invalid from 192.168.1.2',
        'token=HIDDEN and "password":"HIDDEN2"',
        'raw SECRET%2FVALUE',
      ],
    });
    final details = describeHttpFailure(
      utf8.encode(body),
      secrets: ['SECRET/VALUE'],
    );
    for (final secret in [
      'private.invalid',
      'PRIVATE',
      '192.168.1.2',
      'HIDDEN',
      'SECRET',
    ]) {
      expect(details.summary, isNot(contains(secret)));
    }
    final html = describeHttpFailure(
      utf8.encode(
        '<html><script>PRIVATE</script><body>403 Access denied</body></html>',
      ),
    );
    expect(html.format, 'HTML');
    expect(html.summary, contains('403 Access denied'));
    expect(html.summary, isNot(contains('PRIVATE')));
    expect(
      describeHttpFailure(utf8.encode('Bad gateway')).summary,
      contains('Bad gateway'),
    );
  });

  test(
    'missing and malformed bodies are reported as unknown, without cause inference',
    () {
      expect(describeHttpFailure([]).summary, contains('未捕获'));
      final malformed = describeHttpFailure(
        utf8.encode('{"Message":"Emby", "token":"SECRET'),
      );
      expect(malformed.format, contains('JSON 解析失败'));
      expect(malformed.summary, contains('未捕获'));
      expect(malformed.summary, isNot(contains('SECRET')));
      final unknown = describeHttpFailure(utf8.encode('{"unknown":"PRIVATE"}'));
      expect(unknown.structure, contains('其他字段=1 项'));
      expect(unknown.fields, isEmpty);
    },
  );

  test(
    'error reading distinguishes EOF, truncation, timeout, failure and gzip',
    () async {
      final complete = await readDiagnosticBody(
        Stream.value([1, 2, 3]),
        limit: 3,
      );
      expect(complete.state, '完整');
      final oversized = await readDiagnosticBody(
        Stream.value(List.filled(10, 1)),
        limit: 3,
      );
      expect(oversized.state, '已截断');
      expect(oversized.bytes, hasLength(3));
      final silent = StreamController<List<int>>();
      final timedOut = await readDiagnosticBody(
        silent.stream,
        timeout: const Duration(milliseconds: 20),
      );
      expect(timedOut.state, '读取超时');
      await silent.close();
      final interrupted = await readDiagnosticBody(
        Stream<List<int>>.error(const FormatException('PRIVATE')),
      );
      expect(interrupted.state, '读取中断');
      expect(interrupted.failure, 'FormatException');
      final compressed = await readDiagnosticBody(
        Stream.value(gzip.encode(utf8.encode('{"Message":"Denied"}'))),
        encoding: 'gzip',
      );
      expect(compressed.state, '完整');
      expect(describeHttpFailure(compressed.bytes).summary, contains('Denied'));
    },
  );

  test(
    'API logs actual failure and preserves HTTP status without leaking session or login secret',
    () async {
      final log = DiagnosticLog();
      final client = EmbyClient(
        log: log,
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'Message':
                  'Blocked client for 合成账户 SYNTHETIC_TOKEN; password PRIVATE_PASSWORD; use Emby API',
              'ErrorCode': 'CUSTOM_POLICY',
            }),
            403,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ),
        ),
      );
      client.session = syntheticSession();
      await expectLater(
        client.login(
          'http://example.invalid',
          '合成账户',
          'PRIVATE_PASSWORD',
          'test-device',
        ),
        throwsA(predicate((e) => e.toString().contains('HTTP 403'))),
      );
      final exported = log.export();
      expect(exported, contains('CUSTOM_POLICY'));
      expect(exported, contains('use Emby API'));
      expect(exported, contains('HTTP 403'));
      expect(exported, contains('响应头耗时='));
      for (final secret in [
        'SYNTHETIC_TOKEN',
        'PRIVATE_PASSWORD',
        '合成账户',
        'example.invalid',
      ]) {
        expect(exported, isNot(contains(secret)));
      }
      await log.flush();
      log.dispose();
      client.close();
    },
  );

  test(
    'old 300-entry persisted log grows to 5000 without losing history on upgrade',
    () async {
      SharedPreferences.setMockInitialValues({
        DiagnosticLog.entriesKey: List.generate(
          300,
          (i) => LogEntry(
            DateTime.utc(2026),
            '0.0.3',
            LogArea.app,
            LogLevel.info,
            'old $i',
          ).encode(),
        ),
      });
      final log = DiagnosticLog(prefs: await SharedPreferences.getInstance());
      for (var i = 0; i < 4700; i++) {
        log.add(LogArea.app, 'new $i');
      }
      await log.flush();
      expect(log.entries, hasLength(5000));
      expect(log.entries.first.message, 'old 0');
      expect(log.entries.last.message, 'new 4699');
      log.add(LogArea.app, 'next');
      expect(log.entries.first.message, 'old 0');
      expect(log.export(), contains('共 5001 条'));
      log.dispose();
    },
  );
}
