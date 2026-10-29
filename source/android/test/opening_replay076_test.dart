import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/decoder_recovery.dart' as current;
import 'host/replay076/decoder075.dart' as old;

void main() {
  for (final baseline in [true, false]) {
    testWidgets(
      'complete ${baseline ? '0.7.5' : 'current'} verifier with observed restart/reconfigure order',
      (tester) async {
        var frame = false, opened = false;
        final dynamic recovery = baseline
            ? old.DecoderRecovery(
                readOutput: () async => old.VideoOutputState(
                  output: 'gpu',
                  configured: true,
                  frameAvailable: frame,
                  seeking: false,
                  hardwareDecoder: 'mediacodec-copy',
                ),
                onFailure: (_) => fail('unexpected failure'),
                onRecovered: (_) {},
              )
            : current.DecoderRecovery(
                readOutput: () async => current.VideoOutputState(
                  output: 'gpu',
                  configured: true,
                  frameAvailable: frame,
                  seeking: false,
                  hardwareDecoder: 'mediacodec-copy',
                ),
                onFailure: (_) => fail('unexpected failure'),
                onRecovered: (_) {},
              );
        addTearDown(() => recovery.cancel());
        final Future<void> pending = recovery.beginLoad();
        unawaited(pending.then((_) => opened = true));
        recovery.restarted();
        recovery.outputChanged();
        recovery.outputChanged();
        await tester.pump(const Duration(milliseconds: 100));
        expect(opened, false);
        frame = true;
        await tester.pump(const Duration(seconds: 2));
        expect(
          opened,
          !baseline,
          reason:
              'the old class loses the restart, even with a real ready output',
        );
        // Finish the old future cleanly; the new class needs no extra event.
        if (baseline) recovery.restarted();
        await tester.pump();
        expect(opened, true);
      },
    );
  }
}
