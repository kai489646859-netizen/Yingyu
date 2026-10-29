import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/playback/screen_subtitles.dart';
import 'package:yingyu/playback/subtitle_position_memory.dart';
import 'screen_subtitles100_test.dart' show TextNative;
import 'video_retry_test.dart' show StreamVideoController;
import 'host/subtitle102/old_screen_subtitles.dart' as old;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('display geometry follows rotation and retains unknown geometry', () {
    expect(
      subtitlePictureAspect(const VideoParams(dw: 3840, dh: 1606, rotate: 90)),
      closeTo(1606 / 3840, 1e-9),
    );
    expect(
      subtitlePictureAspect(const VideoParams(aspect: 2.4, rotate: 270)),
      closeTo(1 / 2.4, 1e-9),
    );
    expect(subtitlePictureAspect(const VideoParams()), isNull);
    expect(subtitlePictureAspect(const VideoParams(aspect: 0)), isNull);
  });
  for (final size in [
    const Size(915, 412),
    const Size(1280, 837),
    const Size(837, 1280),
  ]) {
    testWidgets(
      'default text anchor uses actual display dimensions when aspect is missing $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final native = TextNative();
        native.state = native.state.copyWith(
          subtitle: ['External subtitle', ''],
          videoParams: const VideoParams(dw: 3840, dh: 1606),
        );
        final controller = StreamVideoController(
          Player(platformPlayer: native),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: old.screenSubtitledVideo(
              picture: const ColoredBox(color: Colors.black),
              controller: controller,
              configuration: const SubtitleViewConfiguration(),
              belowPicture: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.text('External subtitle')).bottom,
          closeTo(size.height - 24, 1),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          MaterialApp(
            home: screenSubtitledVideo(
              picture: const ColoredBox(color: Colors.black),
              controller: controller,
              configuration: const SubtitleViewConfiguration(),
              belowPicture: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final top =
            (size.height + size.width / (3840 / 1606)) / 2 + size.height * .01;
        final text = tester.getRect(find.text('External subtitle'));
        final expected = top.clamp(0.0, size.height - 24 - text.height);
        expect(text.top, closeTo(expected, 1));
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(native.dispose);
        controller.notifier.value?.dispose();
        controller.notifier.dispose();
      },
    );
  }
  test(
    'manual zero persists across a store restart and reset returns to automatic',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final memory = SubtitlePositionMemory(prefs);
      final owner = memory.claim(SubtitleViewport.tablet);
      await memory.save(SubtitleViewport.tablet, owner, 0, active: () => true);
      expect(SubtitlePositionMemory(prefs).read(SubtitleViewport.tablet), 0);
      expect(memory.read(SubtitleViewport.phone), isNull);
      await memory.save(
        SubtitleViewport.tablet,
        owner,
        null,
        active: () => true,
      );
      expect(
        SubtitlePositionMemory(prefs).read(SubtitleViewport.tablet),
        isNull,
      );
    },
  );
  test(
    'retired owner and inactive session cannot overwrite a newer player',
    () async {
      SharedPreferences.setMockInitialValues({});
      final memory = SubtitlePositionMemory(
        await SharedPreferences.getInstance(),
      );
      final old = memory.claim(SubtitleViewport.phone);
      final next = memory.claim(SubtitleViewport.phone);
      await memory.save(SubtitleViewport.phone, next, 35, active: () => true);
      await memory.save(SubtitleViewport.phone, old, 90, active: () => true);
      await memory.save(SubtitleViewport.phone, next, 80, active: () => false);
      expect(memory.read(SubtitleViewport.phone), 35);
    },
  );
  test(
    'invalid stored values retain automatic mode and invalid writes fail',
    () async {
      SharedPreferences.setMockInitialValues({
        'yingyu.subtitles.position.phone.v1': 'broken',
        'yingyu.subtitles.position.tablet.v1': 101.0,
      });
      final memory = SubtitlePositionMemory(
        await SharedPreferences.getInstance(),
      );
      for (final viewport in SubtitleViewport.values) {
        expect(memory.read(viewport), isNull);
      }
      final owner = memory.claim(SubtitleViewport.phone);
      for (final value in [-1.0, 101.0, double.infinity, double.nan]) {
        await expectLater(
          memory.save(SubtitleViewport.phone, owner, value, active: () => true),
          throwsException,
        );
      }
    },
  );
}
