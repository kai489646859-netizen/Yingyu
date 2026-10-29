import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show NativePlaybackEvent;
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:yingyu/playback/diagnostics.dart';
import 'host/error096/backend.dart';

void main() {
  for (final operation in ['read', 'write']) {
    final message = 'tcp: ffurl_$operation returned 0xffffff99';
    test(
      'captured $operation abort leaves the native recovery outcome pending',
      () {
        final backend = ErrorBackendHarness()
          ..route('ffmpeg', 'error', message);
        expect(backend.errors, isEmpty);
        backend.nativeEvent(
          const NativePlaybackEvent(
            mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART,
          ),
        );
        expect(backend.errors, isEmpty);
      },
    );
    test('native terminal error after $operation abort remains fatal', () {
      final backend = ErrorBackendHarness()..route('ffmpeg', 'error', message);
      backend.nativeEvent(
        const NativePlaybackEvent(
          mpv.mpv_event_id.MPV_EVENT_END_FILE,
          reason: mpv.mpv_end_file_reason.MPV_END_FILE_REASON_ERROR,
          error: -13,
        ),
      );
      expect(backend.errors.single, contains('end-file error=-13'));
    });
    test(
      'premature end after $operation abort cannot become a completed film',
      () {
        final backend = ErrorBackendHarness()
          ..route('ffmpeg', 'error', message);
        backend.nativeEvent(
          const NativePlaybackEvent(
            mpv.mpv_event_id.MPV_EVENT_END_FILE,
            reason: mpv.mpv_end_file_reason.MPV_END_FILE_REASON_EOF,
          ),
        );
        expect(backend.errors.single, contains('提前结束'));
        final completed = ErrorBackendHarness()
          ..route('ffmpeg', 'error', message)
          ..position(const Duration(seconds: 100));
        completed.nativeEvent(
          const NativePlaybackEvent(
            mpv.mpv_event_id.MPV_EVENT_END_FILE,
            reason: mpv.mpv_end_file_reason.MPV_END_FILE_REASON_EOF,
          ),
        );
        expect(completed.errors, isEmpty);
      },
    );
  }
  test('only the exact ffmpeg connection-abort messages are provisional', () {
    for (final operation in ['read', 'write']) {
      expect(
        isMpvErrorLog(
          'ffmpeg',
          'error',
          'tcp: ffurl_$operation returned 0xFFFFFF99\n',
        ),
        false,
      );
      for (final text in [
        'tcp: ffurl_$operation returned 0xffffff99; HTTP error 403',
        'tcp: ffurl_$operation returned 0xffffff98',
        'tcp: ffurl_$operation returned 0xffffff9a',
        'tcp: HTTP error 502',
        'tcp: Failed host lookup',
      ]) {
        expect(isMpvErrorLog('ffmpeg', 'error', text), true, reason: text);
      }
      expect(
        isMpvErrorLog(
          'stream',
          'error',
          'tcp: ffurl_$operation returned 0xffffff99',
        ),
        true,
      );
      expect(isMpvErrorLog('vd', 'error', 'Could not open codec.'), true);
    }
  });
}
