import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/screen_subtitles.dart';
import 'package:yingyu/playback/subtitle_size.dart';
import 'screen_subtitles100_test.dart' show TextNative;
import 'offline_capture.dart';
import 'player_episode_menu_test.dart' show fonts;
import 'video_retry_test.dart' show StreamVideoController;

void main() {
  setUpAll(fonts);
  test('text size persists and is independent of encoded resolution', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = AppStore(prefs);
    expect(store.subtitleScale, 1);
    await store.setSubtitleScale(1.5);
    expect(AppStore(prefs).subtitleScale, 1.5);
    expect(
      subtitleFontSize(const Size(844, 390), 1),
      subtitleFontSize(const Size(390, 844), 1),
    );
    expect(
      subtitleFontSize(const Size(1280, 800), 1),
      greaterThan(subtitleFontSize(const Size(844, 390), 1)),
    );
    await expectLater(store.setSubtitleScale(double.nan), throwsException);
    expect(store.subtitleScale, 1.5);
    store.dispose();
  });

  for (final viewport in [
    const Size(390, 844),
    const Size(844, 390),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    testWidgets(
      'main and secondary text resize without replacing picture $viewport',
      (tester) async {
        tester.view.physicalSize = viewport;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final native = TextNative();
        native.state = native.state.copyWith(
          subtitle: ['Primary external cue', 'Secondary cue'],
        );
        final controller = StreamVideoController(
          Player(platformPlayer: native),
        );
        final boundary = GlobalKey();
        const pictureKey = Key('full-source-picture');
        Widget view(double scale) => MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: SubtitleSizeScope(
              scale: scale,
              child: screenSubtitledVideo(
                picture: const Center(
                  child: AspectRatio(
                    aspectRatio: 2.39,
                    child: ColoredBox(key: pictureKey, color: Colors.blue),
                  ),
                ),
                controller: controller,
                configuration: const SubtitleViewConfiguration(),
              ),
            ),
          ),
        );
        await tester.pumpWidget(view(1));
        await tester.pumpAndSettle();
        final picture = tester.getRect(find.byKey(pictureKey));
        final size = tester.getSize(find.text('Primary external cue'));
        await tester.pumpWidget(view(1.5));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(pictureKey)), picture);
        expect(
          tester.getSize(find.text('Primary external cue')).height,
          greaterThan(size.height),
        );
        for (final cue in ['Primary external cue', 'Secondary cue']) {
          final rect = tester.getRect(find.text(cue));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(viewport.width));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(viewport.height));
        }
        await captureOffline(
          tester,
          boundary,
          'subtitle154-${viewport.width.toInt()}x${viewport.height.toInt()}',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(native.dispose);
        controller.notifier.value?.dispose();
      },
    );
  }

  test(
    'contain preserves complete source across phone/tablet and aspect ratios',
    () {
      for (final source in [
        const Size(3840, 1606),
        const Size(3840, 2160),
        const Size(1440, 1080),
        const Size(1080, 1920),
      ]) {
        for (final screen in [
          const Size(390, 844),
          const Size(844, 390),
          const Size(1280, 800),
          const Size(800, 1280),
        ]) {
          final fit = applyBoxFit(BoxFit.contain, source, screen);
          expect(fit.source, source);
          expect(fit.destination.width, lessThanOrEqualTo(screen.width));
          expect(fit.destination.height, lessThanOrEqualTo(screen.height));
          expect(
            fit.destination.aspectRatio,
            closeTo(source.aspectRatio, .0001),
          );
        }
      }
    },
  );
}
