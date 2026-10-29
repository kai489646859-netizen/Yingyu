import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import '../host/opening128/native_subtitles.dart';

void main() {
  test(
    'actual decoder resumes both subtitle cues and preserves secondary text while primary changes',
    () async {
      MediaKit.ensureInitialized(
        libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
      );
      final player = Player();
      final native = player.platform as NativePlayer;
      final hook = HookHarness()
        ..choose = ((tracks) => tracks.firstWhere((t) => t.id == '2'))
        ..openingSecondaryChoice = (tracks) =>
            tracks.firstWhere((t) => t.id == '1');
      try {
        await native.setProperty('vo', 'null');
        await native.setProperty('ao', 'null');
        await native.setProperty('sub-auto', 'no');
        await native.setProperty('vid', 'auto');
        await native.setProperty('sid', '2');
        await hook.beforeOpen(native);
        native.onPreloadedHooks.add(
          () => hook.prepare(native, const Duration(seconds: 3)),
        );
        await player.open(
          Media(
            'D:/Temp/yingyu-playback128-probe/clustered.mkv',
            start: const Duration(seconds: 3),
          ),
          play: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        // ignore: avoid_print
        print('DUAL132 preparation=${hook.log?.rows}; sid=${await native.getProperty("sid")}; secondary=${await native.getProperty("secondary-sid")}; text=${player.state.subtitle}');
        expect(player.state.subtitle, ['CHINESE_CURRENT', 'ENGLISH_CURRENT']);
        expect(await native.getProperty('time-pos'), '3.000000');
        await player.setSubtitleTrack(SubtitleTrack('no', null, null));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(player.state.subtitle[1], 'ENGLISH_CURRENT');
        expect(player.state.playing, false);
        await native.setProperty('secondary-sid', 'no');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(player.state.subtitle[1], '');
      } finally {
        await player.dispose();
      }
    },
  );
}
