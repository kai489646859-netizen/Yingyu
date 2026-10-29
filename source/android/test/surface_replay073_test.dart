import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'host/surface073/listeners.dart';
import 'host/surface073/runtime_health_072.dart' as old;
import 'runtime_health_test.dart' show sample;

void main() {
  for (final mode in ['initial', 'cleanup', 'seeking', 'stale-state']) {
    test('actual 2.0.1 listener counterfactual: $mode', () async {
      final before = OldSurface(), after = CurrentSurface();
      for (final fixture in [before, after]) {
        fixture.wid.value = mode == 'cleanup' ? 0 : 123;
        fixture.platform.values.addAll({
          'video-frame-info/interlaced': mode == 'initial'
              ? 'unavailable'
              : 'no',
          'seeking': mode == 'seeking' ? 'yes' : 'no',
          'idle-active': 'no',
          'time-pos': '597.322',
        });
      }
      await before.widListener();
      await after.widListener();
      expect(before.player.seeks, [Duration.zero]);
      expect(after.player.seeks, isEmpty);
      expect(after.writes, before.writes);
    });
  }
  for (final speed in [1.0, 2.0, 3.0]) {
    test('actual 0.7.2 runtime watch counterfactual at $speed x', () {
      final before = old.RuntimeHealthWatch(), after = RuntimeHealthWatch();
      old.RuntimeSample previous(int now, int audio) => old.RuntimeSample(
        now: Duration(seconds: now),
        position: Duration.zero,
        audioPosition: Duration(seconds: audio),
        playing: true,
        buffering: false,
        seeking: false,
        cachePaused: false,
        outputReady: true,
        hardware: 'mediacodec-copy',
      );
      before.sample(previous(0, 8), speed: speed);
      after.sample(sample(0, 0, 8), speed: speed);
      expect(
        before.sample(previous(6, 14), speed: speed),
        speed > 2 ? old.RuntimeAction.recover : old.RuntimeAction.fail,
      );
      expect(
        after.sample(sample(6, 0, 14), speed: speed),
        RuntimeAction.recover,
      );
    });
  }
}
