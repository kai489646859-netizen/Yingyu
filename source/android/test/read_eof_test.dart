import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/diagnostics.dart';

void main() {
  test('logged TCP AVERROR_EOF must not terminate cached playback', () {
    expect(
      isMpvErrorLog('ffmpeg', 'error', 'tcp: ffurl_read returned 0xdfb9b0bb'),
      isFalse,
    );
    expect(
      isMpvErrorLog('ffmpeg', 'error', 'tcp: ffurl_read returned 0xdfb9b0bb\n'),
      isFalse,
    );
  });
  test('real network and decoder failures remain fatal', () {
    for (final text in [
      'tcp: Connection timed out',
      'tcp: HTTP error 403',
      'tcp: ffurl_read returned 0xdfb9b0bb; additional failure',
    ]) {
      expect(isMpvErrorLog('ffmpeg', 'error', text), isTrue);
    }
    expect(isMpvErrorLog('vd', 'error', 'Could not open codec.'), isTrue);
    expect(isMpvErrorLog('stream', 'error', 'Failed to open'), isTrue);
  });
}
