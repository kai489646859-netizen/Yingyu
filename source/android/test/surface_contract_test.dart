import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/alphabet_rail.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'core_test.dart' show syntheticSession;

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'each accent persists; light and dark labels and accent text meet 4.5:1',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      expect(store.accent, AppAccent.lilac);
      expect(AppAccent.available.take(3), [
        AppAccent.lilac,
        AppAccent.bay,
        AppAccent.emerald,
      ]);
      for (final choice in AppAccent.available) {
        await store.setAccent(choice);
        expect(AppStore(prefs).accent, choice);
        for (final brightness in Brightness.values) {
          final theme = appTheme(brightness, accentChoice: choice);
          for (final background in [
            theme.scaffoldBackgroundColor,
            theme.colorScheme.surface,
            brightness == Brightness.dark
                ? const Color(0xFF2C2C2C)
                : Colors.white,
            // Worst-case bright/dark artwork after the detail scrim.
            brightness == Brightness.dark
                ? const Color(0xFF373737)
                : const Color(0xFFEDEDED),
          ]) {
            for (final foreground in [
              theme.colorScheme.primary,
              theme.colorScheme.onSurface,
              theme.colorScheme.onSurfaceVariant,
            ]) {
              expect(
                contrast(foreground, background),
                greaterThanOrEqualTo(4.5),
                reason: '${choice.name} $brightness $foreground on $background',
              );
            }
          }
          expect(
            contrast(theme.colorScheme.primary, theme.colorScheme.onPrimary),
            greaterThanOrEqualTo(4.5),
          );
        }
      }
      store.dispose();
    },
  );
  for (final size in [
    const Size(412, 915),
    const Size(900, 1280),
    const Size(1280, 800),
  ]) {
    for (final brightness in Brightness.values) {
      for (final menu in [false, true]) {
        testWidgets(
          'player popup round corners and readable labels from $brightness at $size menu=$menu',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            const backdrop = Color(0xFF3C715E);
            final capture = GlobalKey();
            Color? foreground, secondary;
            Brightness? cupertinoBrightness;
            await tester.pumpWidget(
              RepaintBoundary(
                key: capture,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: appTheme(brightness, accentChoice: AppAccent.blush),
                  home: Builder(
                    builder: (context) => Scaffold(
                      backgroundColor: backdrop,
                      body: Center(
                        child: TextButton(
                          onPressed: () =>
                              showSurface<void>(context, (context) {
                                foreground = labelColor(context);
                                secondary = secondaryColor(context);
                                cupertinoBrightness = CupertinoTheme.of(
                                  context,
                                ).brightness;
                                return SurfacePage(
                                  title: menu ? '音频' : '影片与播放信息',
                                  playerMenu: menu,
                                  child: const SettingsGroup(
                                    children: [
                                      SettingsRow(
                                        '英语',
                                        subtitle: 'Dolby TrueHD · 8 声道',
                                      ),
                                    ],
                                  ),
                                );
                              }, playerMenu: true),
                          child: const Text('打开'),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('打开'));
            await tester.pumpAndSettle();
            expect(cupertinoBrightness, Brightness.dark);
            const panelColor = Color(0xFF19191D);
            expect(contrast(foreground!, panelColor), greaterThan(4.5));
            expect(contrast(secondary!, panelColor), greaterThan(4.5));
            final rect = tester.getRect(find.byKey(const Key('surface-panel')));
            await tester.runAsync(() async {
              final boundary =
                  capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary;
              final image = await boundary.toImage();
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              List<int> rgb(int x, int y) => List.generate(
                3,
                (c) => bytes.getUint8((y * image.width + x) * 4 + c),
              );
              final above = rgb(
                (rect.left + 2).floor(),
                (rect.top - 3).floor(),
              );
              expect(
                rgb((rect.left + 1).floor(), (rect.top + 1).floor()),
                above,
              );
              expect(
                rgb((rect.right - 2).floor(), (rect.top + 1).floor()),
                above,
              );
              expect(
                rgb(rect.center.dx.floor(), (rect.top + 4).floor()),
                isNot(above),
              );
              image.dispose();
            });
            expect(tester.takeException(), null);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  for (final brightness in Brightness.values) {
    testWidgets(
      'tablet gutters scroll settings on both sides; pace and color choices save in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final store = AppStore(prefs);
        final api = EmbyClient()..session = syntheticSession();
        final browse = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(brightness),
            home: Scaffold(
              body: SettingsPage(store: store, browse: browse),
            ),
          ),
        );
        final state = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        await tester.dragFrom(const Offset(6, 650), const Offset(0, -220));
        await tester.pumpAndSettle();
        expect(state.position.pixels, greaterThan(0));
        final first = state.position.pixels;
        await tester.dragFrom(const Offset(1274, 650), const Offset(0, -160));
        await tester.pumpAndSettle();
        expect(state.position.pixels, greaterThan(first));
        await tester.scrollUntilVisible(
          find.text('图片加载速度').hitTestable(),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('image-speed-arrow')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            const ValueKey('image-speed-choice-ImageLoadSpeed.balanced'),
          ),
        );
        await tester.pumpAndSettle();
        expect(prefs.getString('yingyu.images.speed.v1'), 'balanced');
        state.position.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('accent-setting-arrow')));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.text('霞光紫').hitTestable().last).dy,
          lessThan(tester.getTopLeft(find.text('流金粉').hitTestable()).dy),
        );
        await tester.tap(find.text('流金粉').hitTestable().last);
        await tester.pumpAndSettle();
        expect(store.accent, AppAccent.blush);
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox());
        browse.dispose();
        api.close();
        store.dispose();
      },
    );
  }
  testWidgets('alphabet press and drag display feedback until release', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 36,
              height: 594,
              child: AlphabetRail(
                available: {'A', 'Z'},
                onSelect: (v) => selected = v,
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('alphabet-letter-A'))),
    );
    await tester.pump(const Duration(milliseconds: 120));
    expect(selected, 'A');
    expect(find.byKey(const Key('alphabet-pressed-feedback')), findsOneWidget);
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('alphabet-letter-Z'))),
    );
    await tester.pump();
    expect(selected, 'Z');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('alphabet-pressed-feedback')), findsNothing);
    expect(tester.takeException(), null);
  });
  for (final choice in AppAccent.available) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'rail availability is distinct and repeated drag coalesces in $choice $brightness',
        (tester) async {
          final selected = <String>[];
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness, accentChoice: choice),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.centerRight,
                  child: SizedBox(
                    width: 36,
                    height: 540,
                    child: AlphabetRail(
                      available: {'A', 'D'},
                      onSelect: selected.add,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('alphabet-available-A')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('alphabet-available-Z')),
            findsNothing,
          );
          final disabled = tester.widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('alphabet-letter-Z')),
              matching: find.byType(Text),
            ),
          );
          expect(disabled.style!.decoration, TextDecoration.lineThrough);
          final available = tester.widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('alphabet-letter-D')),
              matching: find.byType(Text),
            ),
          );
          expect(available.style!.fontWeight, FontWeight.w700);
          expect(available.style!.decoration, TextDecoration.none);
          expect(
            contrast(
              available.style!.color!,
              appTheme(
                brightness,
                accentChoice: choice,
              ).scaffoldBackgroundColor,
            ),
            greaterThanOrEqualTo(4.5),
          );
          final active = tester.widget<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('alphabet-letter-A')),
              matching: find.byType(Text),
            ),
          );
          final tile = tester.widget<Container>(
            find.byKey(const ValueKey('alphabet-letter-A')),
          );
          expect(
            contrast(
              active.style!.color!,
              (tile.decoration! as BoxDecoration).color!,
            ),
            greaterThanOrEqualTo(4.5),
          );
          final point = tester.getCenter(
            find.byKey(const ValueKey('alphabet-letter-A')),
          );
          final gesture = await tester.startGesture(point);
          for (var i = 0; i < 30; i++) {
            await gesture.moveTo(point + Offset(0, (i % 3).toDouble()));
          }
          await tester.pump();
          expect(selected, ['A']);
          await gesture.moveTo(
            tester.getCenter(find.byKey(const ValueKey('alphabet-letter-D'))),
          );
          await tester.pump();
          expect(selected, ['A', 'D']);
          await gesture.moveTo(
            tester.getCenter(find.byKey(const ValueKey('alphabet-letter-Z'))),
          );
          await tester.pump();
          expect(find.text('Z · 无'), findsOneWidget);
          expect(selected, ['A', 'D']);
          await gesture.up();
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  for (final size in [const Size(1280, 800), const Size(915, 412)]) {
    testWidgets('landscape rail keeps original content position at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(toolbarHeight: 62),
            body: Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 36,
                child: AlphabetRail(available: {'A', 'Z'}, onSelect: (_) {}),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byKey(const Key('alphabet-hit-area')));
      expect(rect.center.dy, closeTo((size.height + 62) / 2, 1));
      expect(rect.bottom, lessThanOrEqualTo(size.height));
      expect(
        find.byKey(const ValueKey('alphabet-available-A')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('alphabet-letter-Z')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
}
