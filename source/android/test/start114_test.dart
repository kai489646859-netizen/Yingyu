import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/ui/style.dart';
import 'host/start114/picture.dart';
import 'host/start114/old_picture.dart' as old;
import 'scroll_affordance_test.dart' show fonts;

void main() {
  test(
    'manifest-verified old/current backend comparison catches gamma writes',
    () async {
      final before = old.PictureHarness(), after = PictureHarness();
      await before.setPictureBrightness(15, allowed: () => true);
      await after.setPictureBrightness(15, allowed: () => true);
      expect(before.io.values['gamma'], '15.000');
      expect(after.io.values['gamma'], '0');
      expect(after.generated, contains('yy_picture_gain'));
    },
  );
  test(
    'shadow and overall enhancement coexist in one colour-preserving pass',
    () async {
      final h = PictureHarness();
      await h.setPictureBrightness(10, allowed: () => true);
      await h.enhancement.set(
        .75,
        read: h.io.getProperty,
        write: h.io.setProperty,
        active: () => true,
      );
      expect(h.enhancement.picture, 10);
      expect(h.enhancement.value, .75);
      expect(h.generated, contains('yy_picture_gain'));
      await h.setPictureBrightness(0, allowed: () => true);
      expect(h.enhancement.value, .75);
      expect(h.generated, isNot(contains('yy_picture_gain')));
      await h.enhancement.set(
        0,
        read: h.io.getProperty,
        write: h.io.setProperty,
        active: () => true,
      );
      expect(h.io.values['glsl-shaders'], '');
      expect(h.io.values['gamma'], '0');
      await h.setPictureBrightness(15, allowed: () => true);
      await h.enhancement.set(
        .5,
        read: h.io.getProperty,
        write: h.io.setProperty,
        active: () => true,
      );
      await h.enhancement.set(
        0,
        pictureBrightness: 0,
        read: h.io.getProperty,
        write: h.io.setProperty,
        active: () => true,
      );
      expect(h.enhancement.value, 0);
      expect(h.enhancement.picture, 0);
      expect(h.io.values['glsl-shaders'], '');
    },
  );
  test('export the actual combined shaders for GLSL and CPU colour checks', () {
    final dir = Directory('build/start114/shaders')
      ..createSync(recursive: true);
    for (final transfer in ShadowTransfer.values) {
      for (final shadow in [0.0, .25, .5, .75]) {
        for (final picture in [5.0, 10.0, 15.0]) {
          final shader = shadowShader(transfer, shadow, picture: picture);
          expect(shader, contains('//!HOOK OUTPUT'));
          File(
            '${dir.path}/${transfer.name}-${(shadow * 100).round()}-${picture.round()}.hook',
          ).writeAsStringSync(shader);
        }
      }
    }
  });
  testWidgets('brightness uses only empty half full suns with a crossfade', (
    tester,
  ) async {
    await fonts();
    final capture = GlobalKey();
    Future<void> show(double v) => tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: RepaintBoundary(
          key: capture,
          child: Center(
            child: PlaybackLevelFeedback(brightness: true, level: v),
          ),
        ),
      ),
    );
    double width() => tester
        .widget<ClipRect>(find.byKey(const Key('brightness-sun-fill')))
        .clipper!
        .getClip(const Size(24, 24))
        .width;
    Future<void> save(String name) => tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/start114/previews/brightness-$name.png')
        ..parent.createSync(recursive: true);
      file.writeAsBytesSync(png!.buffer.asUint8List());
      image.dispose();
    });
    await show(0);
    await tester.pumpAndSettle();
    expect(width(), 0);
    expect(find.byIcon(Icons.nightlight_outlined), findsNothing);
    expect(find.byIcon(Icons.wb_sunny_outlined), findsOneWidget);
    await save('empty');
    await show(.5);
    await tester.pumpAndSettle();
    expect(width(), 6);
    await save('half');
    await show(1);
    await tester.pump(const Duration(milliseconds: 40));
    for (final clip in tester.widgetList<ClipRect>(
      find.byKey(const Key('brightness-sun-fill')),
    )) {
      expect(clip.clipper!.getClip(const Size(24, 24)).width, anyOf(0, 6, 12));
    }
    await tester.pumpAndSettle();
    expect(width(), closeTo(12, .001));
    await save('full');
    await show(0);
    await tester.pump(const Duration(milliseconds: 40));
    for (final clip in tester.widgetList<ClipRect>(
      find.byKey(const Key('brightness-sun-fill')),
    )) {
      expect(clip.clipper!.getClip(const Size(24, 24)).width, anyOf(0, 6, 12));
    }
    await tester.pumpAndSettle();
    expect(width(), 0);
    for (var percent = 0; percent <= 100; percent++) {
      expect(BrightnessSun.fillForLevel(percent / 100), anyOf(0, .5, 1));
    }
  });
  test(
    'actual backend overall enhancement does not write channel-wise gamma',
    () async {
      final h = PictureHarness();
      await h.setPictureBrightness(15, allowed: () => true);
      expect(h.io.values['gamma'], '0');
      expect(h.io.writes, everyElement('glsl-shaders'));
      expect(await h.readPictureBrightness(allowed: () => true), 15);
    },
  );
}
