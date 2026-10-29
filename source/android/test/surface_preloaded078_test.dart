import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'host/surface073/listeners.dart';

void main() {
  test(
    'preloaded output configuration is not blocked by pending Surface seek',
    () async {
      for (final current in [false, true]) {
        final SurfaceHarness surface = current
            ? CurrentSurface()
            : OldSurface();
        Future<void> update() => current
            ? (surface as CurrentSurface).widListener()
            : (surface as OldSurface).widListener();
        await update();
        surface.platform.values.addAll({
          'video-frame-info/interlaced': 'no',
          'seeking': 'no',
          'idle-active': 'no',
          'time-pos': '12',
        });
        final gate = surface.player.seekGate = Completer<void>();
        final pending = update();
        await Future<void>.delayed(Duration.zero);
        var configured = false;
        final probe = surface.outputProbe().then((_) {
          configured = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(configured, current);
        gate.complete();
        await pending;
        await probe;
        expect(configured, true);
      }
    },
  );
}
