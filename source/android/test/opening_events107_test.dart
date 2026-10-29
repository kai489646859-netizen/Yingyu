import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'host/playback107/current_events.dart' as current;
import 'host/playback107/old_events.dart' as old;

void main() {
  const baseline = bool.fromEnvironment('OLD_OPENING_107');
  const reconfig = mpv.mpv_event_id.MPV_EVENT_VIDEO_RECONFIG;
  const restart = mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART;
  const seek = mpv.mpv_event_id.MPV_EVENT_SEEK;
  testWidgets(
    'full native event handler: observed AVI fallback opens after a fresh frame',
    (tester) async {
      final dynamic h = baseline
          ? old.OpeningHarness()
          : current.OpeningHarness();
      addTearDown(() => h.close());
      h.start();
      h.codecFailed();
      h.event(reconfig);
      h.event(restart);
      await tester.pump();
      h.event(reconfig);
      h.codecFailed();
      await tester.pump();
      h.frame = true;
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.opened, false);
      h.event(reconfig);
      await tester.pump(const Duration(milliseconds: 100));
      final opened = h.opened;
      h.close();
      await tester.pump();
      expect(
        opened,
        true,
        reason:
            'Fresh reconfigured output after paused fallback must not await a second restart',
      );
      expect(h.recovered, hasLength(1));
      expect(h.failures, isEmpty);
    },
  );
  for (final order in [
    'no restart',
    'seek',
    'no frame',
    'cancel',
    'new load',
  ]) {
    testWidgets('full handler preserves $order guard', (tester) async {
      final h = current.OpeningHarness();
      addTearDown(h.close);
      h.start();
      if (order != 'no restart') h.event(restart);
      await tester.pump();
      h.codecFailed();
      if (order == 'seek') h.event(seek);
      if (order == 'cancel') h.close();
      if (order == 'new load') h.start();
      h.event(reconfig);
      h.frame = order != 'no frame';
      await tester.pump(const Duration(seconds: 2));
      expect(h.opened, false);
      expect(h.recovered, isEmpty);
      expect(h.failures, isEmpty);
      h.close();
      await tester.pump();
    });
  }
}
