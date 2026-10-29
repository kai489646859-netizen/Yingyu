import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/track_selection.dart';
import 'core_test.dart' show syntheticSession;

TrackOption t(
  String id,
  String language, [
  String title = '',
  String codec = 'ass',
]) => TrackOption(
  id,
  trackLabel(id: id, language: language, title: title, codec: codec),
  id,
  language: language,
  title: title,
  codec: codec,
);
const off = TrackOption('no', '关闭', 'no');
const auto = TrackOption('auto', '自动', 'auto');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final language in [
    'zh-Hans',
    'zh_Hans',
    'cmn-Hans-CN',
    'zh-CN',
    'zh-SG',
    'chs',
    'zhs',
    'ＺＨ－ＨＡＮＳ',
  ]) {
    test('explicit simplified $language outranks generic Chinese', () {
      expect(preferredSubtitle([t('1', 'chi'), t('2', language)])?.id, '2');
    });
  }
  for (final title in [
    '简体中文',
    '簡體中文',
    '简中',
    'CHS',
    'SC',
    'Simplified Chinese',
    '［ＣＨＳ］',
    '简英双语',
  ]) {
    test('simplified title $title outranks generic Chinese', () {
      expect(preferredSubtitle([t('1', 'chi'), t('2', 'und', title)])?.id, '2');
    });
  }
  test('PC ranking, ambiguity, complete subtitles, and stable tie order', () {
    final ordered = [
      t('1', 'zh-Hans', '简体'),
      t('2', 'zh-Hans', '简英双语'),
      t('3', 'chi'),
      t('4', 'chi', '中英双语'),
      t('5', 'zh-Hant'),
      t('6', 'zh-Hant', '繁英'),
      t('7', 'en'),
    ];
    for (var i = 0; i < ordered.length; i++) {
      expect(
        preferredSubtitle(ordered.skip(i).toList().reversed.toList())?.id,
        ordered[i].id,
      );
    }
    expect(
      preferredSubtitle([t('1', 'zh-Hant', '简中'), t('2', 'chs')])?.id,
      '2',
    );
    expect(preferredSubtitle([t('1', 'chi', '简繁'), t('2', 'chs')])?.id, '2');
    expect(
      preferredSubtitle([t('1', 'chs', 'Forced'), t('2', 'chs')])?.id,
      '2',
    );
    expect(preferredSubtitle([t('7', 'chs'), t('4', 'chs')])?.id, '7');
    expect(preferredSubtitle([t('1', 'deu', 'FUCHS'), t('2', 'eng')])?.id, '2');
    expect(preferredSubtitle([off, auto, t('1', 'und', 'PGS')])?.id, '1');
  });
  test(
    'disc PID language conflicts and unknown values do not invent labels',
    () {
      final languages = discTrackLanguages([
        {'pid': 4608, 'language': 'zho'},
        {'pid': 4609, 'language': 'eng'},
        {'pid': 4609, 'language': 'jpn'},
        {'pid': 4610, 'language': 'und'},
        {'pid': 0, 'language': 'chi'},
        {'pid': 9000, 'language': 'chi'},
        {'pid': 4611, 'language': 'invalid'},
      ]);
      expect(languages, {4608: 'zho'});
      expect(resolvedTrackLanguage('und', 4608, languages), 'zho');
      expect(resolvedTrackLanguage('und', 1, languages), 'und');
      expect(resolvedTrackLanguage('eng', 4608, languages), 'eng');
      expect(
        resolvedTrackLanguage('und', 4608, languages, external: true),
        'und',
      );
      final label = trackLabel(
        id: '3',
        language: 'zho',
        title: 'HDMV Presentation Graphics',
        codec: 'hdmv_pgs_subtitle',
      );
      expect(label, '中文（PGS）');
      expect(label.contains('简体'), isFalse);
      expect(t('3', 'zho', '', 'hdmv_pgs_subtitle').bitmap, isTrue);
      expect(t('3', 'zho', '', 'ass').bitmap, isFalse);
      expect(
        compactAudioTrackLabel(
          language: 'eng',
          codec: 'truehd',
          channels: 8,
          channelLayout: '7.1',
        ),
        '英语 · TrueHD · 7.1 声道',
      );
      expect(
        compactAudioTrackLabel(language: 'eng', codec: 'truehd', channels: 8),
        '英语 · TrueHD · 8 声道',
      );
      expect(
        compactAudioTrackLabel(
          language: 'eng',
          codec: 'ac3',
          channels: 6,
          channelLayout: '7.1',
        ),
        '英语 · DD · 6 声道',
      );
      expect(
        compactAudioTrackLabel(
          language: 'zho',
          codec: 'ac3',
          channels: 6,
          channelLayout: '5.1(side)',
        ),
        '中文 · DD · 5.1 声道',
      );
      expect(
        compactAudioTrackLabel(
          language: 'eng',
          codec: 'aac',
          channels: 2,
          channelLayout: 'stereo',
        ),
        '英语 · AAC · 立体声',
      );
    },
  );
  test(
    'remembered IDs are validated and series uses unambiguous descriptors',
    () {
      final choice = TrackChoice.fromTrack(t('2', 'eng', 'Original', 'dts'));
      expect(choice.resolve([t('2', 'jpn', 'Original', 'dts')]), isNull);
      expect(choice.resolve([t('3', 'eng', 'Original', 'dts')])?.id, '3');
      expect(
        choice.resolve([
          t('3', 'eng', 'Original', 'dts'),
          t('4', 'eng', 'Original', 'dts'),
        ]),
        isNull,
      );
      final unknown = TrackChoice.fromTrack(t('1', 'und'));
      expect(unknown.resolve([t('1', 'und')], sameItem: false), isNull);
      expect(TrackChoice.fromTrack(off).resolve([auto, off])?.id, 'no');
    },
  );

  late AppStore store;
  late List<TrackOption> subtitles, audio;
  late List<String> calls;
  late Map<bool, String> active;
  Future<void> Function(bool, TrackOption)? operation;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    subtitles = [auto, off, t('1', 'chi'), t('2', 'chs'), t('3', 'eng')];
    audio = [auto, off, t('1', 'eng', '', 'truehd'), t('2', 'chi', '', 'aac')];
    calls = [];
    active = {true: 'no', false: '1'};
    operation = null;
  });
  TrackSelection controller({String item = 'item:movie', String? series}) =>
      TrackSelection(
        store: store,
        account: syntheticSession(),
        itemScope: item,
        seriesScope: series,
        options: (s) => s ? subtitles : audio,
        selected: (s) => active[s],
        onChanged: () {},
        apply: (s, track) async {
          calls.add('${s ? "sub" : "audio"}:${track.id}');
          await operation?.call(s, track);
          active[s] = track.id;
        },
      );

  for (final original in ['eng', 'jpn']) {
    test(
      'automatic simplified subtitles never switch original $original audio',
      () async {
        audio = [auto, off, t('1', original), t('2', 'chi')];
        final c = controller();
        await c.refresh();
        await c.refresh();
        expect(calls, ['sub:2']);
        expect(active[false], '1');
        expect(store.prefs.getString('yingyu.tracks.v1'), isNull);
      },
    );
  }
  test(
    'unknown subtitle fallback preserves honest label and manual off',
    () async {
      subtitles = [auto, off, t('7', 'und', '', 'hdmv_pgs_subtitle')];
      final c = controller();
      await c.refresh();
      expect(active[true], '7');
      expect(subtitles.last.label, contains('语言未知'));
      await c.choose(true, off);
      subtitles.add(t('8', 'und'));
      await c.refresh();
      expect(active[true], 'no');
    },
  );
  test(
    'late known Chinese replaces automatic unknown without touching audio',
    () async {
      subtitles = [auto, off, t('7', 'unknown')];
      final c = controller();
      await c.refresh();
      subtitles.add(t('8', 'chs'));
      await c.refresh();
      expect(active[true], '8');
      expect(active[false], '1');
    },
  );
  test(
    'empty automatic inventory never attempts an invented subtitle',
    () async {
      subtitles = [auto, off];
      await controller().refresh();
      expect(calls, ['sub:no']);
    },
  );
  test(
    'initially selected PGS still receives its rendering setup once',
    () async {
      subtitles = [auto, off, t('2', 'chs', '', 'hdmv_pgs_subtitle')];
      active[true] = '2';
      final c = controller();
      await c.refresh();
      await c.refresh();
      expect(calls, ['sub:2']);
    },
  );
  test(
    'manual off wins after late discovery, restart and next episode',
    () async {
      final c = controller(series: 'series:one');
      await c.refresh();
      await c.choose(true, off);
      subtitles.add(t('8', 'chs', 'new track'));
      await c.refresh();
      expect(active[true], 'no');
      c.close();
      active[true] = 'auto';
      await controller(series: 'series:one').refresh();
      expect(active[true], 'no');
      active[true] = 'auto';
      await controller(item: 'item:episode2', series: 'series:one').refresh();
      expect(active[true], 'no');
    },
  );
  test(
    'manual English survives late simplified metadata; auto explicitly resets memory',
    () async {
      final c = controller();
      await c.refresh();
      await c.choose(true, subtitles.last);
      subtitles.add(t('8', 'chs', 'new preferred'));
      await c.refresh();
      expect(active[true], '3');
      await c.choose(true, auto);
      expect(active[true], '2');
      expect(store.trackChoice(syntheticSession(), 'item:movie', true), isNull);
    },
  );
  test(
    'failed switching is visible and does not persist false success or loop',
    () async {
      operation = (_, _) async => throw const AppFailure('synthetic rejection');
      final c = controller();
      await c.refresh();
      await c.refresh();
      expect(c.warning, contains('synthetic rejection'));
      expect(calls, ['sub:2']);
      expect(active[true], 'no');
      await expectLater(
        c.choose(true, subtitles.last),
        throwsA(isA<AppFailure>()),
      );
      expect(store.trackChoice(syntheticSession(), 'item:movie', true), isNull);
      operation = null;
      await c.choose(true, subtitles.last);
      expect(active[true], '3');
    },
  );
  test('manual selection wins against pending automatic selection', () async {
    final gate = Completer<void>();
    var once = true;
    operation = (_, _) async {
      if (once) {
        once = false;
        await gate.future;
      }
    };
    final c = controller();
    final refresh = c.refresh();
    await Future<void>.delayed(Duration.zero);
    final manual = c.choose(true, off);
    gate.complete();
    await refresh;
    await manual;
    expect(calls, ['sub:2', 'sub:no']);
    expect(active[true], 'no');
  });
  test(
    'close cancels queued choices and does not store a late result',
    () async {
      final gate = Completer<void>();
      operation = (_, _) => gate.future;
      final c = controller();
      final manual = c.choose(true, subtitles.last);
      await Future<void>.delayed(Duration.zero);
      c.close();
      gate.complete();
      await manual;
      await c.choose(true, off);
      expect(calls, ['sub:3']);
      expect(store.trackChoice(syntheticSession(), 'item:movie', true), isNull);
    },
  );
  test(
    'audio explicit selection is remembered only after success; default can be restored',
    () async {
      final c = controller();
      await c.refresh();
      await c.choose(false, audio.last);
      expect(active[false], '2');
      active[false] = '1';
      await controller().refresh();
      expect(active[false], '2');
      await c.choose(false, auto);
      expect(
        store.trackChoice(syntheticSession(), 'item:movie', false),
        isNull,
      );
    },
  );
  test(
    'explicit preferences do not expire after 200 entries and remain account isolated',
    () async {
      final a = syntheticSession();
      final choice = TrackChoice.fromTrack(t('3', 'chs'));
      for (var i = 0; i < 205; i++) {
        await store.saveTrackChoice(a, ['item:$i'], true, choice);
      }
      expect(store.trackChoice(a, 'item:0', true), isNotNull);
      expect(store.trackChoice(a, 'item:204', true), isNotNull);
      final other = Session(
        base: a.base,
        userId: 'other',
        token: a.token,
        username: '',
        deviceId: 'd',
      );
      expect(store.trackChoice(other, 'item:204', true), isNull);
      expect(
        store.prefs.getString('yingyu.tracks.v1'),
        isNot(contains(a.token)),
      );
    },
  );
}
