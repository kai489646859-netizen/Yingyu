import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../host/opening128/native_subtitles.dart';
import '../host/opening128/native_selection.dart' as selection;
import 'package:yingyu/playback/opening_subtitles.dart';
import 'package:yingyu/playback/screen_subtitles.dart';
import '../video_retry_test.dart' show StreamVideoController;

void main() {
  for (final modern in [false, true]) {
    test('actual text decoder: initial spanning cue, preload=$modern', () async {
      MediaKit.ensureInitialized(
        libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
      );
      final player = Player();
      final native = player.platform as NativePlayer;
      final h = HookHarness()
        ..choose = (tracks) => tracks.firstWhere((t) => t.id == '2');
      try {
        await native.setProperty('vo', 'null');
        await native.setProperty('ao', 'null');
        await native.setProperty('vid', 'auto');
        await native.setProperty('sub-auto', 'no');
        await native.setProperty('sid', '2');
        if (modern) {
          await h.beforeOpen(native);
          native.onPreloadedHooks.add(
            () => h.prepare(native, const Duration(seconds: 3)),
          );
        }
        await player.open(
          Media(
            'D:/Temp/yingyu-playback128-probe/clustered.mkv',
            start: const Duration(seconds: 3),
          ),
          play: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(await native.getProperty('time-pos'), '3.000000');
        // ignore: avoid_print
        print(
          'TEXT preload=$modern; format=${await native.getProperty("file-format")}; sid=${await native.getProperty("sid")}; preroll=${await native.getProperty("demuxer-mkv-subtitle-preroll-secs")}; native=${await native.getProperty("sub-text")}; app=${player.state.subtitle}; preparation=${h.log?.rows}',
        );
        expect(player.state.subtitle.first, modern ? 'CHINESE_CURRENT' : '');
        if (modern) {
          final parsed = await readOpeningSubtitles(
            native.getProperty,
            () => true,
          );
          await selection.SubtitleHarness(
            player,
          ).subtitle(parsed.firstWhere((t) => t.id == '2'));
          expect(player.state.subtitle.first, 'CHINESE_CURRENT');
          expect(player.state.playing, false);
        }
        if (!modern) {
          await player.setRate(10);
          await player.play();
          await Future<void>.delayed(const Duration(milliseconds: 400));
          await player.pause();
          expect(player.state.subtitle.first, 'NEXT_CHINESE_CURRENT');
        }
        await h.restore(native);
        expect(
          await native.getProperty('demuxer-mkv-subtitle-preroll-secs'),
          '1.000000',
        );
        expect(h.failure, isNull);
      } finally {
        await player.dispose();
      }
    });
  }
  testWidgets(
    'the spanning cue is visible on the actual Flutter subtitle view at resume',
    (tester) async {
      MediaKit.ensureInitialized(
        libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
      );
      late Player player;
      await tester.runAsync(() async {
        player = Player();
        final native = player.platform as NativePlayer;
        for (final option in {
          'vo': 'null',
          'ao': 'null',
          'vid': 'auto',
          'sub-auto': 'no',
        }.entries) {
          await native.setProperty(option.key, option.value);
        }
        final h = HookHarness()
          ..choose = (tracks) => tracks.firstWhere((t) => t.id == '2');
        await h.beforeOpen(native);
        native.onPreloadedHooks.add(
          () => h.prepare(native, const Duration(seconds: 3)),
        );
        await player.open(
          Media(
            'D:/Temp/yingyu-playback128-probe/clustered.mkv',
            start: const Duration(seconds: 3),
          ),
          play: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await h.restore(native);
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: screenSubtitledVideo(
              picture: const SizedBox.expand(),
              controller: StreamVideoController(player),
              configuration: const SubtitleViewConfiguration(),
            ),
          ),
        );
        await tester.pump();
        expect(find.text('CHINESE_CURRENT'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(player.dispose);
      }
    },
  );
  for (final modern in [false, true]) {
    test(
      'actual PGS decoder: current bitmap at M2TS resume, preload=$modern',
      () async {
        MediaKit.ensureInitialized(
          libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
        );
        final player = Player();
        final native = player.platform as NativePlayer;
        final h = HookHarness()
          ..choose = (tracks) => tracks.firstWhere((t) => t.id == '1');
        try {
          await native.setProperty('vo', 'null');
          await native.setProperty('ao', 'null');
          await native.setProperty('vid', 'auto');
          await native.setProperty('sub-auto', 'no');
          if (modern) {
            await h.beforeOpen(native);
            native.onPreloadedHooks.add(
              () => h.prepare(native, const Duration(seconds: 3)),
            );
          }
          await player.open(
            Media(
              'D:/Temp/yingyu-playback128-probe/bitmap.m2ts',
              start: const Duration(seconds: 3),
            ),
            play: false,
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final start = await native.getProperty(
            'sub-start',
            waitForInitialization: false,
          );
          expect(start.isNotEmpty, modern);
          if (modern) {
            expect(await native.getProperty('time-pos'), '3.000000');
            expect(
              await native.getProperty('sub-end', waitForInitialization: false),
              '5.000000',
            );
            expect(await native.getProperty('sub-visibility'), 'yes');
          }
          final screenshot = File(
            'D:/Temp/yingyu-playback128-probe/app-bitmap-$modern.png',
          );
          if (screenshot.existsSync()) screenshot.deleteSync();
          await native.command([
            'screenshot-to-file',
            'D:/Temp/yingyu-playback128-probe/app-bitmap-$modern.png',
            'subtitles',
          ]);
          expect(screenshot.existsSync(), true);
          await h.restore(native);
          expect(
            await native.getProperty('hr-seek-demuxer-offset'),
            '0.000000',
          );
          expect(player.state.playing, false);
          expect(h.failure, isNull);
        } finally {
          await player.dispose();
        }
      },
    );
  }
  test(
    'four resources in order, pause/rate/seek, then second M2TS resume',
    () async {
      MediaKit.ensureInitialized(
        libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
      );
      final player = Player();
      final native = player.platform as NativePlayer;
      try {
        for (final option in {
          'vo': 'null',
          'ao': 'null',
          'vid': 'auto',
          'sub-auto': 'no',
        }.entries) {
          await native.setProperty(option.key, option.value);
        }
        final cases = [
          (file: 'clustered.mkv', sid: '2', at: 3),
          (file: 'bitmap.m2ts', sid: '1', at: 3),
          (file: 'synthetic.mkv', sid: 'no', at: 3),
          (file: 'hdr.mkv', sid: '1', at: 3),
          (file: 'bitmap.m2ts', sid: '1', at: 4),
        ];
        for (final step in cases) {
          final h = HookHarness()
            ..choose = (tracks) => tracks.firstWhere((t) => t.id == step.sid);
          native.onPreloadedHooks.clear();
          await h.beforeOpen(native);
          native.onPreloadedHooks.add(
            () => h.prepare(native, Duration(seconds: step.at)),
          );
          await player.open(
            Media(
              'D:/Temp/yingyu-playback128-probe/${step.file}',
              start: Duration(seconds: step.at),
            ),
            play: false,
          );
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(await native.getProperty('sid'), step.sid);
          expect(
            double.parse(await native.getProperty('time-pos')),
            closeTo(step.at.toDouble(), .11),
          );
          expect(player.state.playing, false);
          if (step.file == 'clustered.mkv') {
            expect(player.state.subtitle.first, 'CHINESE_CURRENT');
            final parsed = await readOpeningSubtitles(
              native.getProperty,
              () => true,
            );
            await selection.SubtitleHarness(
              player,
            ).subtitle(parsed.firstWhere((t) => t.id == '1'));
            await Future<void>.delayed(const Duration(milliseconds: 100));
            expect(player.state.subtitle.first, 'ENGLISH_CURRENT');
          } else if (step.sid == 'no') {
            expect(player.state.subtitle, ['', '']);
          } else {
            expect(await native.getProperty('sub-start'), isNotEmpty);
            expect(await native.getProperty('sub-visibility'), 'yes');
            if (step.file == 'hdr.mkv') {
              expect(await native.getProperty('video-params/gamma'), 'pq');
            }
          }
          await h.restore(native);
          expect(
            await native.getProperty('hr-seek-demuxer-offset'),
            '0.000000',
          );
          expect(
            await native.getProperty('demuxer-mkv-subtitle-preroll-secs'),
            '1.000000',
          );
          await player.setRate(1.5);
          await player.play();
          await Future<void>.delayed(const Duration(milliseconds: 150));
          await player.pause();
          expect(player.state.playing, false);
          for (final at in [8, 3]) {
            await player.seek(Duration(seconds: at));
            await Future<void>.delayed(const Duration(milliseconds: 150));
            expect(
              double.parse(await native.getProperty('time-pos')),
              closeTo(at.toDouble(), .11),
            );
            expect(player.state.playing, false);
          }
          await player.setRate(1);
          h.active = false;
        }
      } finally {
        await player.dispose();
      }
    },
  );
  test('real media_kit resumes a synthetic cue while initially paused', () async {
    MediaKit.ensureInitialized(
      libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
    );
    final player = Player();
    final native = player.platform as NativePlayer;
    try {
      await native.setProperty('vo', 'null');
      await native.setProperty('ao', 'null');
      await native.setProperty('vid', 'auto');
      await native.setProperty('sub-auto', 'no');
      final events = <List<String>>[];
      final subscription = player.stream.subtitle.listen(events.add);
      await player.open(
        Media(
          'D:/Temp/yingyu-playback128-probe/synthetic.mkv',
          start: const Duration(seconds: 3),
        ),
        play: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final actual = await native.getProperty('sub-text');
      // ignore: avoid_print
      print(
        'SYNTHETIC cue: native=$actual; state=${player.state.subtitle}; events=$events; time=${await native.getProperty("time-pos")}; sid=${await native.getProperty("sid")}; format=${await native.getProperty("file-format")}; vis=${await native.getProperty("sub-visibility")}; codec=${await native.getProperty("current-tracks/sub/codec")}',
      );
      expect(actual, 'ENGLISH_CURRENT');
      expect(player.state.subtitle.first, actual);
      await subscription.cancel();
    } finally {
      await player.dispose();
    }
  });
}
