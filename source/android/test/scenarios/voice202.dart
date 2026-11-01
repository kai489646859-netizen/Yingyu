import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yingyu/playback/audio_balance.dart';

void main() {
  test(
    'actual host PCM keeps voice filter across pause, seek and 2-3-2 rates; off restores chain',
    () async {
      MediaKit.ensureInitialized(
        libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
      );
      final player = Player();
      final native = player.platform as NativePlayer;
      final control = AudioBalanceControl();
      try {
        await native.setProperty('ao', 'null');
        await native.setProperty('vo', 'null');
        await player.open(Media('D:/Temp/yingyu-voice202-probe/voice.wav'));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        final before = await native.getProperty('af');
        final track = await native.getProperty('aid');
        await control.set(
          AudioBalance.voice,
          read: native.getProperty,
          write: native.setProperty,
          active: () => true,
        );
        for (final rate in [2.0, 3.0, 2.0]) {
          await player.setRate(rate);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          expect(await native.getProperty('speed'), rate.toStringAsFixed(6));
          expect(await native.getProperty('af'), contains('@yingyu_balance:'));
        }
        await player.pause();
        await player.seek(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.state.playing, isFalse);
        expect(await native.getProperty('aid'), track);
        await control.set(
          AudioBalance.original,
          read: native.getProperty,
          write: native.setProperty,
          active: () => true,
        );
        expect(await native.getProperty('af'), before);
        expect(player.state.playing, isFalse);
      } finally {
        await player.dispose();
      }
    },
  );
}
