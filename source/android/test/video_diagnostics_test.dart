import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';

void main() {
  test('video warnings retain categories but never native paths or tokens', () {
    final log = VideoDiagnostics();
    expect(
      log.add(
        'vo/gpu',
        'error',
        'shader failure /private/movie.mkv token=SECRET',
      ),
      'vo/error：着色器警告',
    );
    expect(
      log.add(
        'vo/gpu',
        'error',
        'shader https://secret.invalid/?api_key=SECRET',
      ),
      null,
    );
    expect(log.add('vd', 'warn', 'MediaCodec failed SECRET'), 'vd/warn：硬件解码警告');
    expect(log.add('vo/gpu', 'warn', 'EGL context failure'), 'vo/warn：图形上下文警告');
    expect(log.add('vo/gpu', 'info', 'shader success'), null);
    expect(log.add('stream', 'error', 'HTTP 502'), null);
    expect(
      log.add(
        'vo/gpu-next',
        'warn',
        'Discarding obsolete Dolby hardware frame after decoder flush.',
      ),
      'vo/warn：定位后旧代杜比画面已丢弃，等待当前画面',
    );
    log.clear();
    expect(log.add('vo/gpu', 'error', 'shader failed'), isNotNull);
  });
}
