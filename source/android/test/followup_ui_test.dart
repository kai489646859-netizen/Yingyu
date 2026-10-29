import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/expansion_chevron.dart';
import 'package:yingyu/ui/library_layout.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'browse_followup_regression_test.dart' show wallApi;
import 'cache_settings_test.dart' show fonts;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  for (final brightness in Brightness.values) {
    for (final width in [360.0, 800.0, 1280.0]) {
      testWidgets(
        'all settings menus align, rotate and stay compact $brightness $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final store = AppStore(await SharedPreferences.getInstance());
          final api = wallApi();
          final repo = BrowseRepository(
            api,
            BrowseCache(store.prefs),
            BrowsePreferences(store.prefs),
            spacing: Duration.zero,
          );
          final capture = GlobalKey();
          addTearDown(() {
            repo.dispose();
            api.close();
            store.dispose();
          });
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: Scaffold(
                  body: SettingsPage(store: store, browse: repo),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final scroll = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          const choices = {
            'library-display-setting': '媒体库展示',
            'accent-setting': '主题色',
            'hold-speed': '长按播放倍速',
            'translation-network': '语言包下载网络',
            'cache-limit': '图片缓存上限',
            'refresh-interval': '自动刷新间隔',
            'image-auto-clean': '图片自动清理',
            'image-speed': '图片加载速度',
            'image-limit': '图片请求上限',
          };
          for (final entry in choices.entries) {
            scroll.jumpTo(0);
            await tester.pumpAndSettle();
            final arrow = find.byKey(ValueKey('${entry.key}-arrow'));
            await tester.scrollUntilVisible(
              arrow,
              180,
              scrollable: find.byType(Scrollable).first,
            );
            await tester.pumpAndSettle();
            final title = find.text(entry.value);
            final rect = tester.getRect(arrow);
            expect(rect.size, const Size(44, 44));
            expect(tester.getCenter(title).dy, closeTo(rect.center.dy, .1));
            await tester.tap(title);
            await tester.pumpAndSettle();
            Finder entries() =>
                find.byWidgetPredicate((w) => w is PopupMenuItem);
            expect(entries(), findsWidgets);
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            await tester.tap(arrow);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 60));
            final rotation = find.descendant(
              of: arrow,
              matching: find.byType(RotationTransition),
            );
            final angle = tester
                .widget<RotationTransition>(rotation)
                .turns
                .value;
            expect(angle, greaterThan(0));
            expect(angle, lessThan(.25));
            await tester.pumpAndSettle();
            expect(
              tester.widget<RotationTransition>(rotation).turns.value,
              .25,
            );
            final menuRect = tester.getRect(entries().first);
            expect(menuRect.right, closeTo(rect.right, 1));
            expect(menuRect.width, greaterThanOrEqualTo(48));
            expect(menuRect.width, lessThanOrEqualTo(width - 16));
            final menuLabels = find.descendant(
              of: entries(),
              matching: find.byType(Text),
            );
            var longest = 0.0;
            for (final element in menuLabels.evaluate()) {
              final paragraph = element.findRenderObject()! as RenderParagraph;
              final textWidth = paragraph.getMaxIntrinsicWidth(double.infinity);
              if (textWidth > longest) longest = textWidth;
              expect(paragraph.didExceedMaxLines, isFalse);
            }
            expect(
              menuRect.width - longest,
              lessThanOrEqualTo(entry.key == 'accent-setting' ? 64 : 36),
              reason:
                  'The slightly larger settings menu still only reserves icons and row padding',
            );
            expect(menuRect.height, greaterThanOrEqualTo(44));
            expect(
              find.descendant(
                of: entries(),
                matching: find.byIcon(CupertinoIcons.check_mark),
              ),
              findsNothing,
            );
            final highlighted = tester
                .widgetList<Text>(
                  find.descendant(of: entries(), matching: find.byType(Text)),
                )
                .where(
                  (label) =>
                      label.style?.color ==
                      accentColor(tester.element(entries().first)),
                );
            expect(highlighted, hasLength(1));
            if (entry.key == 'image-speed') {
              await tester.runAsync(() async {
                final picture =
                    await (capture.currentContext!.findRenderObject()
                            as RenderRepaintBoundary)
                        .toImage();
                final data = await picture.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                final file = File(
                  'build/ui-previews/$appVersion-settings-menu-${width.toInt()}-${brightness.name}.png',
                );
                await file.parent.create(recursive: true);
                await file.writeAsBytes(data!.buffer.asUint8List());
                picture.dispose();
              });
            }
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(tester.widget<RotationTransition>(rotation).turns.value, 0);
            expect(tester.takeException(), isNull);
          }
          // Switch rows respond across the same row; informational rows do not.
          expect(
            tester
                .widgetList<SettingsRow>(find.byType(SettingsRow))
                .where((w) => w.trailing is CupertinoSwitch && w.onTap == null),
            isEmpty,
          );
          scroll.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('library-display-setting-arrow')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(
              const ValueKey(
                'library-display-setting-choice-LibraryDisplay.posters',
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            InterfacePreferences(store.prefs).libraryDisplay,
            LibraryDisplay.posters,
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
    for (final display in LibraryDisplay.values) {
      testWidgets(
        'rotation follows new scroll anchor, bottom and both appearances $display $brightness',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(1280, 800);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final api = wallApi();
          addTearDown(api.close);
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness),
              home: Scaffold(
                body: LibraryPage(
                  api: api,
                  display: display,
                  onItem: (_) async {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final controller = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .controller!;
          void visibleAtTop(String id) {
            final card = find.byKey(ValueKey(id));
            expect(card, findsOneWidget);
            final viewport = tester.getRect(find.byType(CustomScrollView));
            final rect = tester.getRect(card);
            expect(rect.top, lessThanOrEqualTo(viewport.top + 1));
            expect(rect.bottom, greaterThan(viewport.top));
          }

          for (final row in [0, 9, 21]) {
            final size = tester.view.physicalSize;
            final metrics = LibraryGridMetrics(size.width, 1, display);
            controller.jumpTo(row * (metrics.rowHeight + metrics.spacing));
            await tester.pumpAndSettle();
            final id = 'm${row * metrics.columns}';
            tester.view.physicalSize = size.width == 1280
                ? const Size(800, 1280)
                : const Size(1280, 800);
            await tester.pumpAndSettle();
            visibleAtTop(id);
          }
          controller.jumpTo(controller.position.maxScrollExtent);
          await tester.pumpAndSettle();
          tester.view.physicalSize = const Size(1280, 800);
          await tester.pumpAndSettle();
          expect(
            controller.offset,
            lessThanOrEqualTo(controller.position.maxScrollExtent),
          );
          expect(controller.offset, greaterThan(0));
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
  testWidgets(
    'large text keeps single-line choices and reduced motion remains respected',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 400),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SettingsChoice<int>(
                id: 'large',
                title: '自动清理',
                subtitle: '这是很长的说明文字，用来检查标题和箭头的垂直对齐。',
                choices: const {0: '从不自动清理', 60: '60 天自动清理'},
                value: 0,
                reducedMotion: true,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('large-arrow')));
      await tester.pumpAndSettle();
      final chevron = tester.widget<ExpansionChevron>(
        find.byType(ExpansionChevron),
      );
      expect(chevron.expanded, true);
      expect(tester.widget<Text>(find.text('从不自动清理')).maxLines, 1);
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        Duration.zero,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
