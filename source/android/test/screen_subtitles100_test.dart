import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:yingyu/playback/screen_subtitles.dart';
import 'package:yingyu/version.dart';
import 'video_retry_test.dart' show StreamVideoController;

class TextNative extends PlatformPlayer {
  TextNative() : super(configuration: const PlayerConfiguration(libass: false));
}

void main() {
  for (final size in [
    const Size(915, 412),
    const Size(1280, 837),
    const Size(837, 1280),
  ]) {
    testWidgets(
      'real text subtitles use screen margins at $size, independently of picture aspect',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fontPath = Platform.environment['YINGYU_TEST_FONT'];
        expect(
          fontPath,
          isNotNull,
          reason: 'Bundled offline CJK fixture font is required',
        );
        await tester.runAsync(() async {
          await (FontLoader('ScreenSubtitleFixture')..addFont(
                Future.value(
                  ByteData.sublistView(File(fontPath!).readAsBytesSync()),
                ),
              ))
              .load();
        });
        final native = TextNative();
        native.state = native.state.copyWith(subtitle: ['屏幕字幕 · 保留字形比例', '']);
        final controller = StreamVideoController(
          Player(platformPlayer: native),
        );
        final boundary = GlobalKey();
        const videoKey = Key('letterboxed-picture');
        Widget view(Alignment alignment, {bool visible = true}) => MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: ColoredBox(
              color: Colors.black,
              child: screenSubtitledVideo(
                picture: Center(
                  child: AspectRatio(
                    aspectRatio: 3840 / 1606,
                    child: Container(
                      key: videoKey,
                      color: const Color(0xff193b48),
                    ),
                  ),
                ),
                controller: controller,
                configuration: SubtitleViewConfiguration(
                  alignment: alignment,
                  visible: visible,
                  style: const SubtitleViewConfiguration().style.copyWith(
                    fontFamily: 'ScreenSubtitleFixture',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(view(Alignment.bottomCenter));
        await tester.pumpAndSettle();
        final picture = tester.getRect(find.byKey(videoKey));
        final bottom = tester.getRect(find.text('屏幕字幕 · 保留字形比例'));
        expect(bottom.bottom, closeTo(size.height - 24, 1));
        if (size.height - picture.bottom >= bottom.height + 24) {
          expect(bottom.top, greaterThanOrEqualTo(picture.bottom));
        }
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui-previews/$appVersion-screen-subtitles-${size.width.toInt()}x${size.height.toInt()}-bottom.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(view(Alignment.topCenter));
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('屏幕字幕 · 保留字形比例')).top, closeTo(0, 1));
        if (picture.top >= bottom.height + 24) {
          expect(
            tester.getRect(find.text('屏幕字幕 · 保留字形比例')).bottom,
            lessThanOrEqualTo(picture.top),
          );
        }
        expect(tester.getRect(find.byKey(videoKey)), picture);
        await tester.pumpWidget(view(Alignment.center));
        await tester.pumpAndSettle();
        expect(
          tester.getCenter(find.text('屏幕字幕 · 保留字形比例')).dy,
          closeTo((size.height - 24) / 2, 1),
        );
        await tester.pumpWidget(view(Alignment.bottomCenter, visible: false));
        await tester.pumpAndSettle();
        expect(find.text('屏幕字幕 · 保留字形比例'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(native.dispose);
        controller.notifier.value?.dispose();
        controller.notifier.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
