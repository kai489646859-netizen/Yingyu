import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/tracks.dart';
import 'host/opening128/subtitles.dart' as h;
import 'opening_subtitle128_test.dart' show values;
import 'core_test.dart' show syntheticSession;
import 'opening_metadata098_test.dart' show DetailApi, item;
import 'package:yingyu/playback/opening_metadata.dart';
import 'package:yingyu/core/models.dart';

class OptionalApi extends DetailApi {
  OptionalApi() : super((id) async => item(id));
  int preparations = 0;
  @override
  Future<MediaItem> prepareEpisodeMetadata(String id) async {
    preparations++;
    throw const AppFailure('synthetic optional failure');
  }
}

void main() {
  test(
    'failed optional next preparation falls back to the existing fresh request',
    () async {
      final api = OptionalApi();
      addTearDown(api.close);
      final prep = OpeningMetadata.prepare(api, 'one');
      expect((await prep.take(api, 'one')).id, 'one');
      expect(api.preparations, 1);
      expect(api.calls, 1);
      expect(api.session!.userId, syntheticSession().userId);
    },
  );
  for (final mainOff in [false, true]) {
    test(
      'secondary text selected before initial seek with primary off=$mainOff retains preroll',
      () async {
        final io = h.NativePlayer()..values.addAll(values());
        io.values.addAll({
          'track-list/count': '3',
          'track-list/2/type': 'sub',
          'track-list/2/id': '3',
          'track-list/2/lang': 'eng',
          'track-list/2/codec': 'subrip',
          'track-list/2/external': 'no',
        });
        final hook = h.HookHarness()
          ..choose = ((tracks) =>
              tracks.firstWhere((t) => t.id == (mainOff ? 'no' : '2')))
          ..openingSecondaryChoice = (_) => const TrackOption(
            '3',
            'English',
            '3',
            language: 'eng',
            codec: 'subrip',
          );
        await hook.prepare(io, const Duration(seconds: 20));
        expect(io.values['secondary-sid'], '3');
        expect(io.values['hr-seek-demuxer-offset'], '10');
        expect(hook.secondarySubtitleId, '3');
        expect(hook.failure, isNull);
      },
    );
  }
  test('same primary and secondary track is never duplicated', () async {
    final io = h.NativePlayer()..values.addAll(values());
    final hook = h.HookHarness()
      ..choose = preferredSubtitle
      ..openingSecondaryChoice = preferredSubtitle;
    await hook.prepare(io, const Duration(seconds: 20));
    expect(hook.secondarySubtitleId, 'no');
    expect(io.values['secondary-sid'], isNull);
  });
}
