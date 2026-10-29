import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/scroll_to_top.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'cache_settings_test.dart' show fonts;
import 'offline_capture.dart';

void main() {
  testWidgets(
    'vertical scroll retains the same return button between threshold crossings',
    (tester) async {
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollToTop(
              controller: scroll,
              posterAware: false,
              child: ListView.builder(
                controller: scroll,
                itemCount: 500,
                itemExtent: 60,
                itemBuilder: (_, i) => Text('row $i'),
              ),
            ),
          ),
        ),
      );
      scroll.jumpTo(1400);
      await tester.pump();
      final button = find.byKey(const Key('scroll-to-top'));
      final original = tester.widget<CupertinoButton>(button);
      for (var i = 1; i <= 24; i++) {
        scroll.jumpTo(1400 + i * 5);
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          identical(original, tester.widget<CupertinoButton>(button)),
          true,
        );
      }
      scroll.jumpTo(0);
      await tester.pump();
      expect(button, findsNothing);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
  for (final brightness in Brightness.values) {
    for (final width in [412.0, 1280.0]) {
      testWidgets(
        'group corners match actual sheet background $width $brightness',
        (tester) async {
          tester.view.physicalSize = Size(width, width == 412 ? 915 : 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final capture = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: Scaffold(
                  body: SurfacePage(
                    title: '日志记录',
                    child: ListView(
                      children: [
                        SettingsGroup(
                          children: [
                            SettingsRow(
                              '记录诊断日志',
                              subtitle: '仅保存在本机，已记录 5000/5000 条',
                              trailing: CupertinoSwitch(
                                value: true,
                                onChanged: (_) {},
                              ),
                            ),
                            SettingsRow(
                              '仅警告与错误',
                              trailing: CupertinoSwitch(
                                value: false,
                                onChanged: (_) {},
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final card = tester.getRect(
            find
                .descendant(
                  of: find.byType(SettingsGroup),
                  matching: find.byType(ClipRRect),
                )
                .first,
          );
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            List<int> pixel(Offset point) => List.generate(
              4,
              (i) => bytes.getUint8(
                (point.dy.floor() * image.width + point.dx.floor()) * 4 + i,
              ),
            );
            final background = pixel(card.topLeft + const Offset(-3, 1));
            for (final point in [
              card.topLeft + const Offset(1, 1),
              card.topRight + const Offset(-2, 1),
              card.bottomLeft + const Offset(1, -2),
              card.bottomRight + const Offset(-2, -2),
            ]) {
              expect(pixel(point), background);
            }
            image.dispose();
          });
          await captureOffline(
            tester,
            capture,
            'surface-corners-${width.toInt()}-${brightness.name}',
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
