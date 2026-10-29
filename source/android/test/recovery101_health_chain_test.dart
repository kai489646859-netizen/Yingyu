import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/display_diagnostics.dart';
import 'host/disc_clock085/new/backend.dart';

void main() {
  test(
    'whole periodic sampler catches the captured no-VO advancing-audio pattern',
    () async {
      final backend = BackendHarness()
        ..start(disc: false)
        ..expectVideo();
      backend.checkpoint(620.995);
      for (var seconds = 0; seconds <= 6; seconds += 2) {
        await backend.probeAt(
          seconds * 1000,
          621.0 + seconds,
          621.0 + seconds,
          ready: false,
          hardware: '',
        );
      }
      expect(backend.failure, contains('画面输出已丢失'));
      expect(backend.player.seeks, isEmpty);
      expect(backend.player.rates, isEmpty);
    },
  );
  test(
    'whole periodic sampler retains healthy output and ignores unknown reads',
    () async {
      final backend = BackendHarness()
        ..start(disc: false)
        ..expectVideo();
      for (var seconds = 0; seconds <= 10; seconds += 2) {
        await backend.probeAt(seconds * 1000, 621.0 + seconds, 621.0 + seconds);
      }
      expect(backend.failure, isNull);
      backend.native.beforeRead = (key) async {
        if (key == 'vo-configured') throw StateError('unavailable');
      };
      for (var seconds = 12; seconds <= 22; seconds += 2) {
        await backend.probeAt(seconds * 1000, 621.0 + seconds, 621.0 + seconds);
      }
      expect(backend.failure, isNull);
    },
  );
  test(
    'native failure diagnostics accept only fixed stages and bounded EGL codes',
    () {
      expect(
        nativeHdrFailureStage(
          'Yingyu native HDR rejected: stage=egl-window; egl=3009.\n',
        ),
        'egl-window;egl=3009',
      );
      for (final text in [
        'Yingyu native HDR rejected: stage=https://secret; egl=3009.',
        'Yingyu native HDR rejected: stage=egl-window; egl=3009. token=secret',
        'Yingyu native HDR rejected: stage=unknown; egl=3009.',
        'Yingyu native HDR rejected: stage=renderer; egl=123456789.',
        'unrelated native message',
      ]) {
        expect(nativeHdrFailureStage(text), isNull);
      }
    },
  );
}
