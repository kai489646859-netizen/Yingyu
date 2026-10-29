import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/track_selection.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show syntheticSession;
import 'host/subtitle126/current.dart' as current;
import 'host/subtitle126/old.dart' as old;

TrackOption option(String id, {String codec = 'srt'}) => TrackOption(
  id,
  'Synthetic',
  SubtitleTrack(id, null, null),
  codec: codec,
  language: 'chs',
);

void main() {
  test(
    'automatic same-track selection retains the cue spanning resume',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final h = current.SubtitleHarness();
      final current.NativePlayer io = h.player.platform;
      io.cue('Current cue spanning resume');
      final controller = TrackSelection(
        store: store,
        account: syntheticSession(),
        itemScope: 'synthetic-resume',
        options: (subtitles) => subtitles ? [option('2')] : [],
        selected: (subtitles) => subtitles ? io.values['sid'] : null,
        apply: (subtitles, target) => h.subtitle(target),
        onChanged: () {},
      );
      await controller.refresh();
      expect(io.state.subtitle.first, 'Current cue spanning resume');
      expect(
        io.subtitleController.events.every((cue) => cue.first.isNotEmpty),
        true,
      );
      expect(io.values['sub-visibility'], 'no');
      expect(io.commands, ['sub-visibility']);
      expect(h.refreshes, 1);
      io.cue('Next cue');
      expect(io.state.subtitle.first, 'Next cue');
      controller.close();
    },
  );

  test(
    'complete125 reproduces current cue loss until the next cue event',
    () async {
      final h = old.SubtitleHarness();
      final old.NativePlayer io = h.player.platform;
      io.cue('Current cue spanning resume');
      await h.subtitle(option('2'));
      expect(io.state.subtitle, ['', '']);
      expect(io.commands, ['sid', 'sub-visibility']);
      io.cue('Next cue');
      expect(io.state.subtitle.first, 'Next cue');
    },
  );

  test('real track changes, off and auto still clear stale cues', () async {
    for (final id in ['3', 'no', 'auto']) {
      final h = current.SubtitleHarness();
      final current.NativePlayer io = h.player.platform;
      io.cue('Old cue');
      await h.subtitle(option(id));
      expect(io.state.subtitle, ['', '']);
      expect(io.values['sid'], id);
      expect(io.commands, ['sid', 'sub-visibility']);
    }
  });

  test('same bitmap track still enables native rendering', () async {
    final h = current.SubtitleHarness();
    final current.NativePlayer io = h.player.platform;
    io.values['sub-visibility'] = 'no';
    await h.subtitle(option('2', codec: 'hdmv_pgs_subtitle'));
    expect(io.commands, ['sub-visibility']);
    expect(io.values['sub-visibility'], 'yes');
  });

  test('already loaded external track retains its active text cue', () async {
    final h = current.SubtitleHarness();
    final current.NativePlayer io = h.player.platform;
    const target = TrackOption(
      'local',
      'Synthetic',
      LocalSubtitle('C:/synthetic/a.srt'),
      codec: 'srt',
      external: true,
    );
    await h.subtitle(target);
    expect(io.commands.where((x) => x == 'sub-add'), hasLength(1));
    io.cue('External current cue');
    final start = io.commands.length;
    await h.subtitle(target);
    expect(io.state.subtitle.first, 'External current cue');
    expect(io.commands.skip(start), ['sub-visibility']);
  });

  test('native sid takes precedence over stale Dart track state', () async {
    final h = current.SubtitleHarness();
    final current.NativePlayer io = h.player.platform;
    io.state = io.state.copyWith(
      track: io.state.track.copyWith(
        subtitle: const SubtitleTrack('3', null, null),
      ),
    );
    io.cue('Track two current cue');
    await h.subtitle(option('2'));
    expect(io.state.subtitle.first, 'Track two current cue');
    expect(io.commands, ['sub-visibility']);
    io.values['sid'] = '4';
    await h.subtitle(option('3'));
    expect(io.values['sid'], '3');
    expect(io.state.subtitle, ['', '']);
  });

  test(
    'retired load after sid read cannot select or restore into next load',
    () async {
      final h = current.SubtitleHarness();
      final current.NativePlayer io = h.player.platform;
      var reads = 0;
      io.afterRead = (key) {
        if (key == 'sid' && ++reads == 2) h.retire();
      };
      await expectLater(h.subtitle(option('3')), throwsA(isA<AppFailure>()));
      expect(io.commands, isEmpty);
      expect(h.refreshes, 0);
    },
  );
}
