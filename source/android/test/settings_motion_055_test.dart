import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/ui/style.dart';
import 'cache_settings_test.dart' show fonts;
import 'offline_capture.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('poster menu defaults to 三点 first and retains explicit 长按', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = InterfacePreferences(prefs);
    expect(PosterActionMode.values.map((v) => v.label), ['三点', '长按']);
    expect(settings.posterActionMode, PosterActionMode.menu);
    await settings.setPosterActionMode(PosterActionMode.longPress);
    expect(
      InterfacePreferences(prefs).posterActionMode,
      PosterActionMode.longPress,
    );
    settings.dispose();
  });
  testWidgets('swipe progress only rebuilds the moving indicator', (
    tester,
  ) async {
    final progress = ValueNotifier<double>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: GlassNavigation(
              index: 0,
              progress: progress,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    final tab = find.byKey(const Key('navigation-tab-0'));
    final original = tester.widget<CupertinoButton>(tab);
    final indicator = find.byKey(const Key('navigation-glass-indicator'));
    final start = tester.getTopLeft(indicator).dx,
        width = tester.getSize(indicator).width;
    for (var i = 1; i <= 12; i++) {
      progress.value = i / 12;
      await tester.pump(const Duration(milliseconds: 16));
      expect(identical(tester.widget<CupertinoButton>(tab), original), true);
      expect(
        tester.getTopLeft(indicator).dx,
        closeTo(start + width * i / 12, .01),
      );
    }
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    progress.dispose();
  });
  for (final width in [412.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'shared row feedback and equal quota typography $width $brightness',
        (tester) async {
          tester.view.physicalSize = Size(width, width == 412 ? 915 : 800);
          tester.view.devicePixelRatio = 1;
          tester.view.display.size = tester.view.physicalSize;
          tester.view.display.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.display.resetSize);
          addTearDown(tester.view.display.resetDevicePixelRatio);
          await fonts();
          final boundary = GlobalKey();
          var selected = 3;
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: Scaffold(
                  body: SafeArea(
                    child: Column(
                      children: [
                        SettingsGroup(
                          title: '图片',
                          children: [
                            SettingsChoice<int>(
                              id: 'quota',
                              title: '图片请求上限',
                              subtitle: '仅限制新图片请求',
                              icon: CupertinoIcons.photo,
                              value: 3,
                              choices: {
                                for (final v
                                    in InterfacePreferences.imageRequestLimits)
                                  v: v == 0 ? '无上限' : '每秒最多 $v 张',
                              },
                              onChanged: (v) => selected = v,
                            ),
                          ],
                        ),
                        const Spacer(),
                        GlassNavigation(index: 2, onChanged: (_) {}),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          final row = find.byKey(const Key('quota'));
          expect(
            find.descendant(of: row, matching: find.byType(CupertinoButton)),
            findsOneWidget,
          );
          for (final target in [
            find.text('图片请求上限'),
            find.byKey(const Key('quota-arrow')),
          ]) {
            final gesture = await tester.startGesture(tester.getCenter(target));
            await tester.pump();
            final overlay = find.byKey(const Key('poster-pressed'));
            expect(overlay, findsOneWidget);
            expect(tester.getRect(overlay), tester.getRect(row));
            await gesture.up();
            await tester.pumpAndSettle();
            expect(overlay, findsNothing);
            TextStyle style(String text) {
              final rich = find.descendant(
                of: find.text(text),
                matching: find.byType(RichText),
              );
              final render = tester.renderObject<RenderParagraph>(rich);
              return (render.text as TextSpan).style!;
            }

            final unlimited = style('无上限');
            for (final v in [1, 2, 3]) {
              final limited = style('每秒最多 $v 张');
              expect(limited.fontFamily, unlimited.fontFamily);
              expect(limited.fontWeight, unlimited.fontWeight);
              expect(limited.fontSize, unlimited.fontSize);
              expect(limited.height, unlimited.height);
              expect(limited.fontFamilyFallback, unlimited.fontFamilyFallback);
            }
            expect(unlimited.fontSize, width == 412 ? 15 : 16);
            expect(unlimited.fontWeight, FontWeight.w400);
            await captureOffline(
              tester,
              boundary,
              'quota-font-${width.toInt()}-${brightness.name}',
            );
            await tester.tap(find.text('无上限'));
            await tester.pumpAndSettle();
            expect(selected, 0);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
