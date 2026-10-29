import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';

void main() {
  for (final size in [
    const Size(412, 915),
    const Size(900, 1280),
    const Size(1280, 800),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'surface close button has no shadow or filter at $size $brightness',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.runAsync(() async {
            await ui.FragmentProgram.fromAsset(
              'packages/liquid_glass_widgets/shaders/lightweight_glass.frag',
            );
            await LightweightLiquidGlass.preWarm();
          });
          final capture = GlobalKey(), marker = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness),
              home: RepaintBoundary(
                key: capture,
                child: SurfacePage(
                  title: '合成详情',
                  detail: true,
                  child: Center(
                    child: SizedBox(
                      key: marker,
                      width: 200,
                      height: 160,
                      child: const Row(
                        children: [
                          Expanded(
                            child: ColoredBox(
                              color: Colors.white,
                              child: SizedBox.expand(),
                            ),
                          ),
                          Expanded(
                            child: ColoredBox(
                              color: Colors.black,
                              child: SizedBox.expand(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(GlassButton), findsNothing);
          expect(find.byType(BackdropFilter), findsNothing);
          final closeRect = tester.getRect(find.byType(SurfaceIcon));
          expect(closeRect.size, const Size(44, 44));
          final rect = tester.getRect(find.byKey(marker));
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final wide = size.width >= 600 && size.width > size.height;
            final themed = appTheme(
              brightness,
            ).scaffoldBackgroundColor.toARGB32();
            final background = wide
                ? (brightness == Brightness.dark
                      ? [44, 44, 44]
                      : [255, 255, 255])
                : [(themed >> 16) & 255, (themed >> 8) & 255, themed & 255];
            for (final point in [
              closeRect.topLeft + const Offset(1, 1),
              closeRect.topRight + const Offset(-2, 1),
              closeRect.bottomLeft + const Offset(1, -2),
              closeRect.bottomRight + const Offset(-2, -2),
            ]) {
              for (var channel = 0; channel < 3; channel++) {
                final expected = background[channel];
                expect(
                  bytes.getUint8(
                    (point.dy.toInt() * image.width + point.dx.toInt()) * 4 +
                        channel,
                  ),
                  expected,
                );
              }
            }
            for (final y in [
              rect.top.toInt() + 40,
              rect.center.dy.toInt(),
              rect.bottom.toInt() - 40,
            ]) {
              for (var channel = 0; channel < 3; channel++) {
                expect(
                  bytes.getUint8(
                    (y * image.width + rect.center.dx.toInt() - 1) * 4 +
                        channel,
                  ),
                  255,
                );
                expect(
                  bytes.getUint8(
                    (y * image.width + rect.center.dx.toInt()) * 4 + channel,
                  ),
                  0,
                );
              }
            }
            image.dispose();
          });
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'loaded glass shader cannot blur page content outside navigation',
    (tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        // Fail if the real shader cannot load, instead of testing its no-blur
        // initial fallback and reporting a false success.
        await ui.FragmentProgram.fromAsset(
          'packages/liquid_glass_widgets/shaders/lightweight_glass.frag',
        );
        await LightweightLiquidGlass.preWarm();
      });
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: RepaintBoundary(
            key: boundaryKey,
            child: Stack(
              children: [
                const Positioned.fill(
                  child: Row(
                    children: [
                      Expanded(
                        child: ColoredBox(
                          color: Colors.white,
                          child: SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: Colors.black,
                          child: SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 6,
                  child: GlassNavigation(index: 3, onChanged: (_) {}),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final rgba = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        for (var y = 40; y < 500; y += 80) {
          // The boundary between adjacent white/black pixels remains perfectly
          // sharp even after glass shader loading and selected-tab painting.
          for (var channel = 0; channel < 3; channel++) {
            expect(rgba.getUint8((y * 400 + 199) * 4 + channel), 255);
            expect(rgba.getUint8((y * 400 + 200) * 4 + channel), 0);
          }
        }
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}
