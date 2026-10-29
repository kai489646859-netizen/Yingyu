import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/image_loading.dart';
import 'package:yingyu/core/offline_translation.dart';
import 'package:yingyu/ui/offline_translation.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'offline_translation_test.dart' show FakeTranslation;

void expectHighlighted(WidgetTester tester, Finder choice) {
  final label = find.descendant(of: choice, matching: find.byType(Text)).first;
  expect(
    tester.widget<Text>(label).style!.color,
    accentColor(tester.element(label)),
  );
  expect(
    find.descendant(
      of: choice,
      matching: find.byIcon(CupertinoIcons.check_mark),
    ),
    findsNothing,
  );
}

Future<void> fonts() async {
  final path = Platform.environment['YINGYU_TEST_FONT'];
  if (path != null) {
    for (final family in [
      'Roboto',
      'Ahem',
      '.SF UI Text',
      '.SF UI Display',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
    ]) {
      await (FontLoader(family)..addFont(
            Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
          ))
          .load();
    }
  }
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      ))
      .load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'defaults are fast, five minutes and never clean; explicit choices persist',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = InterfacePreferences(prefs);
      expect(settings.imageLoadSpeed, ImageLoadSpeed.fast);
      expect(BrowsePreferences(prefs).minutes, 5);
      expect(settings.imageAutoCleanDays, 0);
      for (final days in [15, 30, 60, 0]) {
        await settings.setImageAutoCleanDays(days);
        expect(InterfacePreferences(prefs).imageAutoCleanDays, days);
      }
      await settings.setImageLoadSpeed(ImageLoadSpeed.slow);
      await BrowsePreferences(prefs).setMinutes(30);
      final saved = {for (final key in prefs.getKeys()) key: prefs.get(key)!};
      SharedPreferences.setMockInitialValues(saved);
      final restored = await SharedPreferences.getInstance();
      expect(
        InterfacePreferences(restored).imageLoadSpeed,
        ImageLoadSpeed.slow,
      );
      expect(BrowsePreferences(restored).minutes, 30);
      expect(InterfacePreferences(restored).imageAutoCleanDays, 0);
      settings.dispose();
    },
  );
  for (final dark in [false, true]) {
    for (final landscape in [false, true]) {
      testWidgets(
        'checked cleanup menu and compact translation actions dark=$dark landscape=$landscape',
        (tester) async {
          tester.view.physicalSize = landscape
              ? const Size(800, 400)
              : const Size(412, 915);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final previousShadows = debugDisableShadows;
          debugDisableShadows = false;
          addTearDown(() => debugDisableShadows = previousShadows);
          final prefs = await SharedPreferences.getInstance();
          final preferences = InterfacePreferences(prefs);
          final backend = FakeTranslation()..value = const TranslationStatus();
          final translation = OfflineTranslation(prefs, platform: backend);
          final capture = GlobalKey();
          Future<void> preview(String name) async {
            await tester.runAsync(() async {
              final image =
                  await (capture.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/ui-previews/$appVersion-$name-${dark ? 'dark' : 'light'}-${landscape ? 'wide' : 'phone'}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }

          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(dark ? Brightness.dark : Brightness.light),
                home: Scaffold(
                  body: SafeArea(
                    child: ListView(
                      children: [
                        AnimatedBuilder(
                          animation: preferences,
                          builder: (_, _) => SettingsChoice<int>(
                            id: 'image-auto-clean',
                            title: '图片自动清理',
                            subtitle:
                                '${InterfacePreferences.imageAutoCleanChoices[preferences.imageAutoCleanDays]} · 仅清理长期未使用的详情大图，容量满时仍先清理大图',
                            icon: CupertinoIcons.calendar,
                            value: preferences.imageAutoCleanDays,
                            choices: InterfacePreferences.imageAutoCleanChoices,
                            onChanged: preferences.setImageAutoCleanDays,
                          ),
                        ),
                        OfflineTranslationGroup(service: translation),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('图片自动清理'));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('image-auto-clean-choice-0')),
            findsOneWidget,
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          final arrow = find.byKey(const ValueKey('image-auto-clean-arrow'));
          final anchor = tester.getRect(arrow);
          await tester.tap(arrow);
          await tester.pumpAndSettle();
          final defaultChoice = find.byKey(
            const ValueKey('image-auto-clean-choice-0'),
          );
          expect(tester.getRect(defaultChoice).right, closeTo(anchor.right, 1));
          expect(
            tester.getRect(defaultChoice).top,
            greaterThanOrEqualTo(anchor.bottom),
          );
          expectHighlighted(tester, defaultChoice);
          await preview('cleanup-choices');
          await tester.tap(
            find.byKey(const ValueKey('image-auto-clean-choice-30')),
          );
          await tester.pumpAndSettle();
          expect(preferences.imageAutoCleanDays, 30);
          await tester.tap(
            find.byKey(const ValueKey('image-auto-clean-arrow')),
          );
          await tester.pumpAndSettle();
          expectHighlighted(
            tester,
            find.byKey(const ValueKey('image-auto-clean-choice-30')),
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const ValueKey('translation-network')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('translation-network-arrow')),
          );
          await tester.pumpAndSettle();
          expectHighlighted(
            tester,
            find.byKey(const ValueKey('translation-network-choice-true')),
          );
          await preview('translation-network');
          await tester.tap(
            find.byKey(const ValueKey('translation-network-choice-false')),
          );
          await tester.pumpAndSettle();
          expect(translation.wifiOnly, false);
          expect(OfflineTranslation(prefs, platform: backend).wifiOnly, false);
          expect(backend.downloads, 0);
          final download = tester.widget<CupertinoButton>(
            find.byKey(const Key('translation-download')),
          );
          expect(
            download.color,
            isNull,
            reason: 'download keeps the existing theme fill',
          );
          backend.value = const TranslationStatus(ready: true);
          await translation.refresh();
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(const Key('translation-delete')),
          );
          await tester.pumpAndSettle();
          final button = find.byKey(const Key('translation-delete'));
          expect(
            tester.widget<CupertinoButton>(button).color,
            CupertinoColors.systemRed.resolveFrom(tester.element(button)),
          );
          expect(find.byKey(const Key('translation-download')), findsNothing);
          expect(find.text('删除语言包'), findsNothing);
          expect(tester.getSize(button).width, lessThan(100));
          expect(
            (tester.getCenter(button).dy -
                    tester.getCenter(find.text('英语简介 → 中文')).dy)
                .abs(),
            lessThan(1),
          );
          await preview('translation-delete');
          await tester.tap(button);
          await tester.pumpAndSettle();
          expect(find.text('删除离线语言包？'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(translation.status.ready, true);
          await tester.tap(button);
          await tester.pumpAndSettle();
          await tester.tap(find.widgetWithText(CupertinoDialogAction, '删除'));
          await tester.pumpAndSettle();
          expect(translation.status.ready, false);
          expect(find.byKey(const Key('translation-download')), findsOneWidget);
          expect(backend.downloads, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          translation.dispose();
          preferences.dispose();
          debugDisableShadows = previousShadows;
        },
      );
    }
  }
}
