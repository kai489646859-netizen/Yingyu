import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/screen_subtitles.dart';
import 'package:yingyu/version.dart';
import 'screen_subtitles100_test.dart' show TextNative;
import 'video_retry_test.dart' show StreamVideoController;

void main() {
  for (final target in [null, 0.0, 45.0, 100.0]) {
    test(
      'native placement transaction $target preserves selection and delay',
      () async {
        final values = {
          'yingyu-subtitle-below-picture': 'yes',
          'sub-pos': '65',
          'sid': 'no',
          'sub-delay': '1.5',
        };
        final writes = <String>[];
        await writeMpvSubtitlePlacement(
          position: target,
          read: (k) async => values[k]!,
          write: (k, v) async {
            writes.add(k);
            values[k] = v;
          },
          active: () => true,
        );
        expect(
          values['yingyu-subtitle-below-picture'],
          target == null ? 'yes' : 'no',
        );
        expect(
          double.parse(values['sub-pos']!),
          target == null ? 65 : 100 - target,
        );
        expect(values['sid'], 'no');
        expect(values['sub-delay'], '1.5');
        expect(
          writes.every(
            (k) => k == 'sub-pos' || k == 'yingyu-subtitle-below-picture',
          ),
          true,
        );
      },
    );
  }
  for (final rejected in ['yingyu-subtitle-below-picture', 'sub-pos']) {
    test(
      'a rejected $rejected restores both native placement properties',
      () async {
        final values = {
          'yingyu-subtitle-below-picture': 'yes',
          'sub-pos': '65',
        };
        var refused = false;
        await expectLater(
          writeMpvSubtitlePlacement(
            position: 0,
            read: (k) async => values[k]!,
            write: (k, v) async {
              if (k == rejected && !refused) {
                refused = true;
                return;
              }
              values[k] = v;
            },
            active: () => true,
          ),
          throwsException,
        );
        expect(values['yingyu-subtitle-below-picture'], 'yes');
        expect(double.parse(values['sub-pos']!), 65);
      },
    );
  }
  test(
    'a retired placement request cannot restore into another load',
    () async {
      var active = true;
      final writes = <String>[];
      await expectLater(
        writeMpvSubtitlePlacement(
          position: 0,
          read: (k) async => k == 'sub-pos' ? '100' : 'yes',
          write: (k, v) async {
            writes.add(k);
            active = false;
          },
          active: () => active,
        ),
        throwsException,
      );
      expect(writes, ['yingyu-subtitle-below-picture']);
    },
  );
  for (final size in [
    const Size(1280, 837),
    const Size(837, 1280),
    const Size(915, 412),
  ]) {
    testWidgets(
      'default below picture, manual screen bottom, fill and reset at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final path = Platform.environment['YINGYU_TEST_FONT'];
        expect(path, isNotNull);
        await tester.runAsync(() async {
          await (FontLoader('Subtitle107Fixture')..addFont(
                Future.value(
                  ByteData.sublistView(File(path!).readAsBytesSync()),
                ),
              ))
              .load();
        });
        final native = TextNative();
        native.state = native.state.copyWith(
          subtitle: ['画面下方的默认字幕\n第二行也保留完整字形', ''],
        );
        final controller = StreamVideoController(
          Player(platformPlayer: native),
        );
        final boundary = GlobalKey();
        double? defaultPosition;
        void report(double value) {
          defaultPosition = value;
        }

        const videoKey = Key('subtitle107-picture');
        Widget view({
          bool automatic = true,
          bool fill = false,
          double aspect = 3840 / 1606,
        }) => MaterialApp(
          home: RepaintBoundary(
            key: boundary,
            child: ColoredBox(
              color: Colors.black,
              child: screenSubtitledVideo(
                picture: Center(
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: Container(
                      key: videoKey,
                      color: const Color(0xff193b48),
                    ),
                  ),
                ),
                controller: controller,
                pictureAspect: aspect,
                belowPicture: automatic,
                fill: fill,
                onDefaultPosition: report,
                configuration: SubtitleViewConfiguration(
                  style: const SubtitleViewConfiguration().style.copyWith(
                    fontFamily: 'Subtitle107Fixture',
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        final text = find.text('画面下方的默认字幕\n第二行也保留完整字形');
        final image = tester.getRect(find.byKey(videoKey));
        final caption = tester.getRect(text);
        final target = (image.bottom + size.height * .01).clamp(
          0.0,
          size.height - 24 - caption.height,
        );
        expect(caption.top, closeTo(target, 1));
        final travel = size.height - 24 - caption.height;
        expect(
          defaultPosition,
          closeTo(travel > 0 ? 100 * (1 - caption.top / travel) : 0, .001),
        );
        expect(caption.bottom, lessThanOrEqualTo(size.height - 23));
        if (size.height - image.bottom >=
            caption.height + 24 + size.height * .01) {
          expect(caption.top, greaterThan(image.bottom));
        }
        await tester.runAsync(() async {
          final rendered =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(
            'build/ui-previews/$appVersion-subtitle-default-${size.width.toInt()}x${size.height.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          rendered.dispose();
        });
        await tester.pumpWidget(view(automatic: false));
        await tester.pumpAndSettle();
        expect(tester.getRect(text).bottom, closeTo(size.height - 24, 1));
        expect(tester.getRect(find.byKey(videoKey)), image);
        await tester.pumpWidget(view(fill: true));
        await tester.pumpAndSettle();
        expect(tester.getRect(text).bottom, closeTo(size.height - 24, 1));
        await tester.pumpWidget(view());
        await tester.pumpAndSettle();
        expect(tester.getRect(text), caption);
        await tester.pumpWidget(view(aspect: 4 / 3));
        await tester.pumpAndSettle();
        final changed = tester.getRect(find.byKey(videoKey));
        final moved = tester.getRect(text);
        expect(
          moved.top,
          closeTo(
            (changed.bottom + size.height * .01).clamp(
              0.0,
              size.height - 24 - moved.height,
            ),
            1,
          ),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(native.dispose);
        controller.notifier.value?.dispose();
        controller.notifier.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
