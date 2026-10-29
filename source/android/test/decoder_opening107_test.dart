import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/decoder_recovery.dart';

const _frame = VideoOutputState(
  output: 'gpu',
  configured: true,
  frameAvailable: true,
  seeking: false,
  hardwareDecoder: 'no',
);

void main() {
  testWidgets(
    '0.10.6 AVI order: a second init warning after restart, then a real reconfigured frame',
    (tester) async {
      var opened = false, frame = false;
      final recovered = <VideoOutputState>[];
      final recovery = DecoderRecovery(
        readOutput: () async => frame
            ? _frame
            : const VideoOutputState(
                output: 'gpu',
                configured: true,
                frameAvailable: false,
                seeking: false,
                hardwareDecoder: 'no',
              ),
        onFailure: (_) => fail('unexpected runtime recovery'),
        onRecovered: recovered.add,
      );
      addTearDown(recovery.cancel);
      unawaited(recovery.beginLoad().then((_) => opened = true));
      // Exported session 338: 46.199, .200, .225, .226, .227, .238,
      // .242, .665, .666. The independent buffer probe sees a real frame at .760.
      recovery.codecFailed('Could not open codec.');
      recovery.outputChanged();
      recovery.outputChanged();
      recovery.outputChanged();
      recovery.restarted();
      await tester.pump();
      recovery.outputChanged();
      recovery.outputChanged();
      recovery.codecFailed('Could not open codec.');
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, false);
      recovery.outputChanged();
      recovery.outputChanged();
      frame = true;
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        opened,
        true,
        reason: 'a paused first frame need not emit another playback-restart',
      );
      expect(recovered, hasLength(1));
    },
  );
}
