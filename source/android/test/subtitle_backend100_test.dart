import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/tracks.dart';
import 'host/release100/old_subtitles.dart' as old;
import 'host/release100/current_subtitles.dart' as current;

void main() {
  for (final value in [('1', 'srt'), ('2', 'hdmv_pgs_subtitle'), ('no', '')]) {
    test(
      'complete old/current subtitle selection preserves $value, with one refresh',
      () async {
        final before = old.SubtitleHarness(), after = current.SubtitleHarness();
        final option = TrackOption(
          value.$1,
          'Synthetic',
          SubtitleTrack(value.$1, null, null),
          codec: value.$2,
        );
        await before.subtitle(option);
        await after.subtitle(option);
        expect(after.player.platform.values, before.player.platform.values);
        expect(
          after.player.platform.commands,
          value.$1 == '2'
              ? [
                  'sub-visibility',
                ] // Already selected; preserve the current cue.
              : before.player.platform.commands,
        );
        expect(after.refreshes, 1);
        expect(before.refreshes, 2);
      },
    );
  }
  test(
    'chosen local file is added once, confirmed, mapped and reselected without reopening it',
    () async {
      final h = current.SubtitleHarness();
      const option = TrackOption(
        'manual-1',
        'Synthetic',
        LocalSubtitle('C:/synthetic/chosen.srt'),
        codec: 'srt',
        external: true,
      );
      await h.subtitle(option);
      expect(h.player.platform.values['sid'], '10');
      expect(h.externalIds['manual-1'], '10');
      expect(h.player.platform.values['sub-visibility'], 'no');
      expect(h.privatePaths, isNotEmpty);
      await h.subtitle(option);
      expect(h.player.platform.commands.where((s) => s == 'sub-add').length, 1);
      expect(
        h.player.platform.commands.every(
          (s) => {'sub-add', 'sid', 'sub-visibility'}.contains(s),
        ),
        true,
      );
    },
  );
  test(
    'unconfirmed local subtitle restores original sid and visibility',
    () async {
      final h = current.SubtitleHarness()..player.platform.mismatch = true;
      await expectLater(
        h.subtitle(
          const TrackOption(
            'manual-1',
            'Synthetic',
            LocalSubtitle('C:/synthetic/chosen.srt'),
            codec: 'srt',
          ),
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(h.player.platform.values, {'sid': '2', 'sub-visibility': 'yes'});
      expect(h.externalIds, isEmpty);
    },
  );
  test(
    'retired load cannot write late visibility or restore old sid into next media',
    () async {
      final h = current.SubtitleHarness();
      h.player.platform.afterAdd = h.retire;
      await expectLater(
        h.subtitle(
          const TrackOption(
            'manual-1',
            'Synthetic',
            LocalSubtitle('C:/synthetic/chosen.srt'),
            codec: 'srt',
          ),
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(h.player.platform.commands, ['sub-add']);
      expect(h.refreshes, 0);
    },
  );
}
