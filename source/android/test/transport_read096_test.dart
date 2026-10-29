import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';

void main() {
  test(
    'logged recoverable timeout must allow native reconnect and cached playback',
    () {
      expect(
        isMpvErrorLog('ffmpeg', 'error', 'tcp: ffurl_read returned 0xffffff92'),
        isFalse,
      );
    },
  );
  test(
    'timeout exception is exact and cannot swallow HTTP or decoder failures',
    () {
      for (final value in [
        'tcp: Connection timed out',
        'tcp: HTTP error 403',
        'tcp: ffurl_read returned 0xffffff92; additional failure',
        'tcp: ffurl_read returned 0xffffff91',
        'tcp: ffurl_read returned 0xffffff98',
      ]) {
        expect(isMpvErrorLog('ffmpeg', 'error', value), isTrue);
      }
      expect(
        isTransportReadTimeout(
          'ffmpeg',
          'error',
          'tcp: ffurl_read returned 0xFFFFFF92\n',
        ),
        isTrue,
      );
      expect(
        isTransportReadTimeout(
          'stream',
          'error',
          'tcp: ffurl_read returned 0xffffff92',
        ),
        isFalse,
      );
      expect(isMpvErrorLog('stream', 'error', 'Failed to open'), isTrue);
      expect(isMpvErrorLog('vd', 'error', 'Could not open codec.'), isTrue);
    },
  );
}
