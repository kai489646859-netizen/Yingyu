import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';

void main() {
  test(
    'HTTP detail survives the later generic Failed to open without secrets',
    () {
      final diagnostics = PlaybackDiagnostics();
      diagnostics.add(
        'ffmpeg',
        'error',
        'https: HTTP error 403 Forbidden https://cdn.invalid/?sign=SECRET',
      );
      final result = diagnostics.describe(
        'Failed to open https://cdn.invalid/?sign=SECRET',
      );
      expect(result, contains('HTTP 403'));
      expect(result, contains('Failed to open'));
      expect(result, isNot(contains('SECRET')));
      expect(result, isNot(contains('cdn.invalid')));
    },
  );
  test(
    'TLS DNS timeout and redirect failures retain only bounded categories',
    () {
      final diagnostics = PlaybackDiagnostics();
      for (final entry in {
        'tls: certificate verification failed secret': 'TLS 证书校验失败',
        'tcp: Failed to resolve hostname secret': '媒体主机名称解析失败',
        'tcp: Connection timed out secret': '媒体网络请求超时',
        'http: too many redirects secret': '媒体地址重定向失败',
      }.entries) {
        diagnostics.clear();
        expect(diagnostics.add('ffmpeg', 'error', entry.key), true);
        expect(diagnostics.describe('打开失败'), contains(entry.value));
        expect(diagnostics.describe('打开失败'), isNot(contains('secret')));
      }
      diagnostics.clear();
      expect(diagnostics.describe('打开失败'), '打开失败');
    },
  );
  test(
    'unrelated logs and debug credentials do not enter network diagnostics',
    () {
      final diagnostics = PlaybackDiagnostics();
      expect(
        diagnostics.add('ffmpeg', 'debug', 'HTTP 403 Cookie: SECRET'),
        false,
      );
      expect(
        diagnostics.add('vd', 'error', 'HTTP 403 fictional metadata'),
        false,
      );
      expect(diagnostics.add('ffmpeg', 'warn', 'Cookie: SECRET'), false);
      expect(diagnostics.describe('打开失败'), '打开失败');
      expect(
        diagnostics.describe(
          'HTTP 401\nAuthorization: Bearer SECRET\nCookie: PRIVATE',
        ),
        allOf(
          contains('HTTP 401'),
          isNot(contains('SECRET')),
          isNot(contains('PRIVATE')),
        ),
      );
    },
  );
}
