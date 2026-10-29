import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/opening_subtitles.dart';
import 'package:yingyu/playback/track_selection.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show syntheticSession;
import 'host/opening128/subtitles.dart' as h;

Map<String, String> values({String codec = 'subrip'}) => {
  'path': 'synthetic',
  'track-list/count': '2',
  'track-list/0/type': 'video',
  'track-list/1/type': 'sub',
  'track-list/1/id': '2',
  'track-list/1/lang': 'chs',
  'track-list/1/title': '简体中文',
  'track-list/1/codec': codec,
  'track-list/1/src-id': '4608',
  'track-list/1/ff-index': '1',
  'track-list/1/external': 'no',
  'options/sid': 'auto',
  'sub-visibility': 'no',
  'file-format': 'mpegts',
  'hr-seek-demuxer-offset': '0.000000',
  'demuxer-mkv-subtitle-preroll-secs': '1.000000',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'saved choice wins over server off before initial seek, matching normal refresh',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final account = syntheticSession();
      final list = await readOpeningSubtitles(
        (k) async => values()[k] ?? '',
        () => true,
      );
      final off = list.firstWhere((t) => t.id == 'no');
      final applied = <String>[];
      final selection = TrackSelection(
        store: store,
        account: account,
        itemScope: 'synthetic',
        options: (_) => list,
        selected: (_) => null,
        apply: (s, t) async {
          if (s) applied.add(t.id);
        },
        onChanged: () {},
        serverDefault: (_) => -1,
        serverOption: (_, _) => off,
        serverIndex: (_, t) => t.id == 'no' ? -1 : int.tryParse(t.id),
      );
      expect(selection.openingSubtitle(list)?.id, 'no');
      await store.saveTrackChoice(
        account,
        ['synthetic'],
        true,
        TrackChoice.fromTrack(list.last),
      );
      expect(selection.openingSubtitle(list)?.id, '2');
      expect(applied, isEmpty);
      await selection.refresh();
      expect(applied, ['2']);
      selection.close();
    },
  );
  test(
    'inherited language choice resolves in newly parsed IDs without changing memory',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final original = await readOpeningSubtitles(
        (k) async => values()[k] ?? '',
        () => true,
      );
      final changed = await readOpeningSubtitles(
        (k) async => (values()..['track-list/1/id'] = '7')[k] ?? '',
        () => true,
      );
      final selection = TrackSelection(
        store: store,
        account: syntheticSession(),
        itemScope: 'next',
        options: (_) => changed,
        inheritedChoices: {true: TrackChoice.fromTrack(original.last)},
        selected: (_) => null,
        apply: (_, _) async {},
        onChanged: () {},
      );
      expect(selection.openingSubtitle(changed)?.id, '7');
      expect(selection.continuityChoices[true], isNotNull);
      selection.close();
    },
  );
  for (final brokenRestore in [false, true]) {
    test(
      'unacknowledged preselection restores state or reports its real failure: $brokenRestore',
      () async {
        final io = h.NativePlayer()..values.addAll(values());
        final hook = h.HookHarness()..choose = preferredSubtitle;
        io.onWrite = (key, value) {
          if (key == 'sid' && (value == '2' || brokenRestore)) {
            io.values['options/sid'] = 'unconfirmed';
          }
        };
        await hook.prepare(io, const Duration(seconds: 20));
        expect(hook.failure != null, brokenRestore);
        if (!brokenRestore) expect(io.values['options/sid'], 'auto');
        expect(io.values['hr-seek-demuxer-offset'], '0.000000');
      },
    );
  }
  for (final codec in ['subrip', 'ass', 'hdmv_pgs_subtitle', 'dvd_subtitle']) {
    test(
      'whole preload chooses $codec before seek and restores the exact input option',
      () async {
        final io = h.NativePlayer()..values.addAll(values(codec: codec));
        final hook = h.HookHarness()..choose = preferredSubtitle;
        await hook.prepare(io, const Duration(seconds: 20));
        expect(io.values['options/sid'], '2');
        expect(
          io.values['sub-visibility'],
          codec.contains('subtitle') ? 'yes' : 'no',
        );
        expect(io.values['hr-seek-demuxer-offset'], '10');
        expect(hook.failure, isNull);
        await hook.restore(io);
        expect(io.values['hr-seek-demuxer-offset'], '0.000000');
      },
    );
  }
  test(
    'disc PID language recovery matches the existing post-open policy',
    () async {
      final io = h.NativePlayer()
        ..values.addAll(
          values()
            ..['track-list/1/lang'] = ''
            ..['track-list/1/title'] = '',
        );
      final hook = h.HookHarness()
        ..discLanguages = {4608: 'chs'}
        ..choose = preferredSubtitle;
      await hook.prepare(io, const Duration(seconds: 20));
      expect(io.values['options/sid'], '2');
    },
  );
  test('explicit subtitle off is applied without a preroll read', () async {
    final io = h.NativePlayer()..values.addAll(values());
    final hook = h.HookHarness()
      ..choose = (tracks) => tracks.firstWhere((t) => t.id == 'no');
    await hook.prepare(io, const Duration(seconds: 20));
    expect(io.values['options/sid'], 'no');
    expect(io.values['sub-visibility'], 'no');
    expect(io.values['hr-seek-demuxer-offset'], '0.000000');
  });
  test('starting at zero preselects but adds no preceding input', () async {
    final io = h.NativePlayer()..values.addAll(values());
    final hook = h.HookHarness()..choose = preferredSubtitle;
    await hook.prepare(io, Duration.zero);
    expect(io.values['options/sid'], '2');
    expect(io.values['hr-seek-demuxer-offset'], '0.000000');
  });
  test(
    'external selection remains on its existing full-file loading path',
    () async {
      final io = h.NativePlayer()..values.addAll(values());
      final hook = h.HookHarness()
        ..choose = (_) => const TrackOption(
          'external-3',
          'Synthetic',
          LocalSubtitle('C:/synthetic/a.srt'),
          external: true,
        );
      await hook.prepare(io, const Duration(seconds: 20));
      expect(io.writes, isEmpty);
    },
  );
  test(
    'a retired load cannot publish visibility or a later read window',
    () async {
      final io = h.NativePlayer()..values.addAll(values());
      final hook = h.HookHarness()..choose = preferredSubtitle;
      io.onWrite = (key, _) {
        if (key == 'sid') hook.active = false;
      };
      await hook.prepare(io, const Duration(seconds: 20));
      expect(io.writes, ['sid=2']);
    },
  );
  for (final bad in ['0', '513', 'unknown']) {
    test('unknown track count $bad never chooses a guessed track', () async {
      final io = h.NativePlayer()
        ..values.addAll(values()..['track-list/count'] = bad);
      final hook = h.HookHarness()..choose = preferredSubtitle;
      await hook.prepare(io, const Duration(seconds: 20));
      expect(io.writes, isEmpty);
    });
  }
  for (final container in [
    'mkv',
    'matroska',
    'webm',
    'mpegts',
    'mov,mp4,m4a,3gp,3g2,mj2',
  ]) {
    test('read window for $container uses only its matching option', () async {
      final io = h.NativePlayer()..values.addAll(values());
      final setup = OpeningSubtitleRead();
      expect(
        await setup.prepare(
          container: container,
          read: io.getProperty,
          write: io.setProperty,
          active: () => true,
        ),
        true,
      );
      expect(io.writes, [
        container == 'mkv' || container == 'matroska' || container == 'webm'
            ? 'demuxer-mkv-subtitle-preroll-secs=10'
            : 'hr-seek-demuxer-offset=10',
      ]);
      await setup.restore(read: io.getProperty, write: io.setProperty);
      expect(io.values['hr-seek-demuxer-offset'], '0.000000');
      expect(io.values['demuxer-mkv-subtitle-preroll-secs'], '1.000000');
    });
  }
  test('MKV snapshot and generic offset can coexist, restoring both', () async {
    final io = h.NativePlayer()..values.addAll(values());
    final setup = OpeningSubtitleRead();
    for (final format in ['mkv', 'mpegts']) {
      expect(
        await setup.prepare(
          container: format,
          read: io.getProperty,
          write: io.setProperty,
          active: () => true,
        ),
        true,
      );
    }
    await setup.restore(read: io.getProperty, write: io.setProperty);
    expect(io.values['demuxer-mkv-subtitle-preroll-secs'], '1.000000');
    expect(io.values['hr-seek-demuxer-offset'], '0.000000');
  });
  test('newer restore owns IO while an old read reply is pending', () async {
    final io = h.NativePlayer()..values.addAll(values());
    final setup = OpeningSubtitleRead();
    final gate = Completer<String>();
    var reads = 0;
    final job = setup.prepare(
      container: 'mpegts',
      read: (key) async => ++reads == 2 ? gate.future : io.getProperty(key),
      write: io.setProperty,
      active: () => true,
    );
    await Future<void>.delayed(Duration.zero);
    await setup.restore(read: io.getProperty, write: io.setProperty);
    gate.complete('10');
    expect(await job, false);
    expect(io.values['hr-seek-demuxer-offset'], '0.000000');
  });
  test('failed restoration remains a real error', () async {
    final io = h.NativePlayer()..values.addAll(values());
    final setup = OpeningSubtitleRead();
    await setup.prepare(
      container: 'mpegts',
      read: io.getProperty,
      write: io.setProperty,
      active: () => true,
    );
    await expectLater(
      setup.restore(read: io.getProperty, write: (_, _) async {}),
      throwsA(isA<AppFailure>()),
    );
    await setup.restore(read: io.getProperty, write: io.setProperty);
  });
  for (final auto in [false, true]) {
    test(
      'opening policy equals normal selection, auto=$auto and no persistence side effects',
      () async {
        SharedPreferences.setMockInitialValues({
          'yingyu.subtitles.auto.v1': auto,
        });
        final store = AppStore(await SharedPreferences.getInstance());
        final list = await readOpeningSubtitles(
          (k) async => values()[k] ?? '',
          () => true,
        );
        final applied = <String>[];
        final selection = TrackSelection(
          store: store,
          account: syntheticSession(),
          itemScope: 'synthetic',
          options: (_) => list,
          selected: (_) => null,
          apply: (subtitles, track) async {
            if (subtitles) applied.add(track.id);
          },
          onChanged: () {},
        );
        final preview = selection.openingSubtitle(list);
        expect(applied, isEmpty);
        await selection.refresh();
        expect(applied, [preview!.id]);
        selection.close();
      },
    );
  }
}
