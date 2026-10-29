import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/track_selection.dart';
import 'core_test.dart' show syntheticSession;
import 'track_selection_test.dart' show t, off, auto;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('subtitle menu distinguishes scripts without guessing generic PGS', () {
    for (final entry in {'chs': '简中', 'cht': '繁中', 'chi': '中文'}.entries) {
      final track = subtitleMetadata(
        t('1', entry.key, '', 'hdmv_pgs_subtitle'),
        [],
      );
      expect(track.label, equals('${entry.value}（PGS）'));
    }
  });
  test(
    'exact stream evidence supplements script but preserves manual descriptors',
    () {
      const native = TrackOption(
        '7',
        '中文 · PGS',
        'native-value',
        language: 'chi',
        codec: 'hdmv_pgs_subtitle',
        ffIndex: 4,
        isDefault: true,
      );
      final enriched = subtitleMetadata(native, [
        {
          'Type': 'Subtitle',
          'Index': 4,
          'Codec': 'pgs',
          'Language': 'zh-Hans',
          'Title': '简体中文',
          'DisplayTitle': 'Chinese (PGS)',
        },
        {'Type': 'Subtitle', 'Index': 5, 'Codec': 'pgs', 'Language': 'zh-Hant'},
      ]);
      expect(enriched.label, equals('简中（PGS）'));
      expect(enriched.isDefault, isTrue);
      expect(enriched.value, native.value);
      expect(enriched.title, native.title);
      expect(enriched.language, native.language);
      expect(TrackChoice.fromTrack(native).resolve([enriched])?.id, '7');
      expect(preferredSubtitle([t('2', 'chi'), enriched])?.id, '7');
    },
  );
  test(
    'ambiguous source metadata cannot turn an unidentified disc track into simplified',
    () {
      final native = t('2', 'chi', '', 'pgs');
      final mapped = subtitleMetadata(native, [
        for (final index in [3, 4])
          {
            'Type': 'Subtitle',
            'Index': index,
            'Codec': 'pgs',
            'Language': 'chi',
            'Title': index == 3 ? '简体中文' : '繁体中文',
          },
      ]);
      expect(mapped.label, startsWith('中文'));
      expect(mapped.subtitleHint, isEmpty);
    },
  );
  test(
    'simplified automatic preference beats generic server default; explicit choices still win',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final options = [auto, off, t('1', 'chi'), t('2', 'chs'), t('3', 'cht')];
      var active = '1';
      TrackSelection controller() => TrackSelection(
        store: store,
        account: syntheticSession(),
        itemScope: 'item:fixture',
        options: (subtitles) => subtitles ? options : [],
        selected: (_) => active,
        apply: (_, track) async => active = track.id,
        onChanged: () {},
        serverDefault: (s) => s ? 8 : null,
        serverOption: (_, _) => options[2],
      );
      final first = controller();
      await first.refresh();
      expect(active, '2');
      await first.choose(true, options[4]);
      first.close();
      active = '1';
      final next = controller();
      await next.refresh();
      expect(active, '3');
      next.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    },
  );
}
