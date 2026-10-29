import 'package:flutter_test/flutter_test.dart';
import 'host/opening128/demand.dart';

void main() {
  test(
    'late initial buffering while paused never requests starvation recovery',
    () {
      final h = Harness()
        ..playing(false)
        ..buffering(true);
      expect(h.hint, false);
    },
  );
  test(
    'running starvation, pause and resume jointly update the same demand',
    () {
      final h = Harness()
        ..playing(true)
        ..buffering(true);
      expect(h.hint, true);
      h.playing(false);
      expect(h.hint, false);
      h.playing(true);
      expect(h.hint, true);
      h.buffering(false);
      expect(h.hint, false);
    },
  );
  test('opening buffers do not qualify until real requested playback', () {
    final h = Harness()..opening = true;
    h.playing(true);
    h.buffering(true);
    expect(h.hint, false);
    h.opening = false;
    h.buffering(true);
    expect(h.hint, true);
  });
  test(
    '256 callback combinations preserve current playback and buffer state',
    () {
      final h = Harness();
      for (var i = 0; i < 256; i++) {
        final playing = i & 1 != 0, buffering = i & 2 != 0;
        if (i & 4 != 0) {
          h.playing(playing);
          h.buffering(buffering);
        } else {
          h.buffering(buffering);
          h.playing(playing);
        }
        expect(h.hint, playing && buffering);
      }
    },
  );
}
