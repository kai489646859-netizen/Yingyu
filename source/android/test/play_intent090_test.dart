import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/audio_decode_watch.dart';
import 'host/play090/backend.dart';
import 'host/play090/old_audio.dart' as old;
import 'runtime_health_test.dart' show sample;

void main() {
  for (final action in ['pause', 'close', 'new load']) {
    test('complete production play cannot unpause after $action', () async {
      final harness = Harness();
      final native = harness.player.platform as NativePlayer;
      final playing = harness.play();
      await native.entered.future;
      if (action == 'pause') {
        await harness.pause();
      }
      if (action == 'close') {
        harness.close();
      }
      if (action == 'new load') {
        harness.supersede();
      }
      native.ready.complete();
      await playing;
      expect(harness.player.plays, 0);
      expect(harness.readAhead, false);
      expect(harness.playingSince, null);
    });
  }
  test(
    'complete play waits once and subsequent play returns normally',
    () async {
      final harness = Harness();
      final native = harness.player.platform as NativePlayer;
      final playing = harness.play();
      await native.entered.future;
      expect(harness.player.plays, 0);
      native.ready.complete();
      await playing;
      await harness.pause();
      await harness.play();
      expect(harness.player.plays, 2);
      expect(harness.readAhead, true);
    },
  );
  test('ordinary media keeps immediate production play', () async {
    final harness = Harness()..ordinary();
    await harness.play();
    expect(harness.player.plays, 1);
    expect(
      (harness.player.platform as NativePlayer).entered.isCompleted,
      false,
    );
  });
  for (final mode in ['buffering', 'cachePaused', 'seeking']) {
    test('same sample exposes delivered 089 audio false timeout: $mode', () {
      final before = old.AudioDecodeWatch()
        ..fault(Duration.zero, playing: true);
      final after = AudioDecodeWatch()..fault(Duration.zero, playing: true);
      before.sample(sample(1, 1, 1));
      after.sample(sample(1, 1, 1));
      final waiting = sample(
        56,
        1,
        1,
        buffering: mode == 'buffering',
        cachePaused: mode == 'cachePaused',
        seeking: mode == 'seeking',
      );
      expect(before.sample(waiting), old.AudioDecodeAction.fail);
      expect(after.sample(waiting), AudioDecodeAction.none);
      expect(after.sample(sample(57, 1, 1)), AudioDecodeAction.none);
      expect(after.sample(sample(58, 2, 2)), AudioDecodeAction.verified);
    });
  }
}
