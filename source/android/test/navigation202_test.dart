import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/swipe_pages.dart';
import 'offline_capture.dart';
import 'scroll_affordance_test.dart' show fonts;

void main() {
  for (final reduce in [false, true]) {
    testWidgets(
      'edge clamping and direct drag on a different tab; reduced=$reduce',
      (tester) async {
        var selected = 0;
        final calls = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, set) => Align(
                  alignment: Alignment.bottomCenter,
                  child: GlassNavigation(
                    index: selected,
                    reducedMotion: reduce,
                    onChanged: (i) {
                      calls.add(i);
                      set(() => selected = i);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        final second = tester.getCenter(
          find.byKey(const Key('navigation-tab-2')),
        );
        final first = tester.getCenter(
          find.byKey(const Key('navigation-tab-0')),
        );
        final last = tester.getCenter(
          find.byKey(const Key('navigation-tab-3')),
        );
        final thumb = find.byKey(const Key('navigation-glass-indicator'));
        final gesture = await tester.startGesture(second);
        await gesture.moveBy(const Offset(24, 0));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 180));
        expect(calls, isEmpty);
        expect(tester.getCenter(thumb).dx, closeTo(second.dx + 24, .01));
        await gesture.moveTo(Offset(-100, second.dy));
        await tester.pump();
        expect(tester.getCenter(thumb).dx, closeTo(first.dx, .01));
        await gesture.moveTo(Offset(last.dx + 200, second.dy));
        await tester.pump();
        expect(tester.getCenter(thumb).dx, closeTo(last.dx, .01));
        expect(calls, isEmpty);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, [3]);
        expect(selected, 3);
        expect(tester.getCenter(thumb).dx, closeTo(last.dx, .01));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final size in [
    const Size(412, 915),
    const Size(800, 360),
    const Size(1280, 800),
  ]) {
    for (final glass in [false, true]) {
      testWidgets(
        'continuous scrub retains buttons and commits once $size glass=$glass',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.display.size = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.display.resetSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final capture = GlobalKey();
          final progress = ValueNotifier<double>(0);
          final calls = <int>[];
          var selected = 0, parentBuilds = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(
                  Brightness.dark,
                  visualStyle: glass
                      ? VisualStyle.liquidGlass
                      : VisualStyle.traditional,
                ),
                home: Scaffold(
                  body: StatefulBuilder(
                    builder: (context, set) {
                      parentBuilds++;
                      return Align(
                        alignment: Alignment.bottomCenter,
                        child: GlassNavigation(
                          index: selected,
                          progress: progress,
                          onChanged: (i) {
                            calls.add(i);
                            set(() => selected = i);
                            // Deliberately let actual page progress lag the commit.
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final first = tester.getRect(
            find.byKey(const Key('navigation-tab-0')),
          );
          final thumb = find.byKey(const Key('navigation-glass-indicator'));
          final gesture = await tester.startGesture(first.center);
          await gesture.moveBy(const Offset(24, 0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 180));
          final button = tester.widget<CupertinoButton>(
            find.byKey(const Key('navigation-tab-0')),
          );
          final backdrop = tester.widget<BackdropFilter>(
            find.byType(BackdropFilter).first,
          );
          final builds = parentBuilds;
          // Non-integer positions, reversals and 120 Hz-sized steps. No page work.
          for (var i = 1; i <= 90; i++) {
            if (i == 45) progress.value = 1.7;
            final page = i <= 30
                ? i / 30 * 2.8
                : i <= 60
                ? 2.8 - (i - 30) / 30 * 2.4
                : .4 + (i - 60) / 30 * 1.95;
            final x = first.center.dx + first.width * page;
            await gesture.moveTo(Offset(x, first.center.dy));
            await tester.pump(const Duration(microseconds: 8333));
            expect(tester.getCenter(thumb).dx, closeTo(x, .01));
            expect(selected, 0);
            expect(calls, isEmpty);
            expect(parentBuilds, builds);
            expect(
              identical(
                tester.widget<CupertinoButton>(
                  find.byKey(const Key('navigation-tab-0')),
                ),
                button,
              ),
              isTrue,
            );
            expect(
              identical(
                tester.widget<BackdropFilter>(
                  find.byType(BackdropFilter).first,
                ),
                backdrop,
              ),
              isTrue,
            );
          }
          await captureOffline(
            tester,
            capture,
            'navigation202-held-${size.width.toInt()}-${glass ? 'glass' : 'classic'}',
          );
          await gesture.up();
          await tester.pump();
          expect(calls, [2]);
          expect(selected, 2);
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            tester.getCenter(thumb).dx,
            closeTo(first.center.dx + first.width * 2, .01),
          );
          // Old page pixels must not pull the released highlight backwards.
          for (final page in [.3, .9, 1.4, 1.9, 2.0]) {
            progress.value = page;
            await tester.pump();
            expect(
              tester.getCenter(thumb).dx,
              closeTo(first.center.dx + first.width * 2, .01),
            );
          }
          await tester.pumpAndSettle();
          await captureOffline(
            tester,
            capture,
            'navigation202-settled-${size.width.toInt()}-${glass ? 'glass' : 'classic'}',
          );
          await tester.pumpWidget(const SizedBox());
          progress.dispose();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final cancelKind in ['pointer', 'background', 'outside', 'resize']) {
    testWidgets('$cancelKind cancels a held preview without selecting', (
      tester,
    ) async {
      final calls = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: GlassNavigation(index: 0, onChanged: calls.add),
            ),
          ),
        ),
      );
      final first = tester.getCenter(find.byKey(const Key('navigation-tab-0')));
      final last = tester.getCenter(find.byKey(const Key('navigation-tab-3')));
      final gesture = await tester.startGesture(first);
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await gesture.moveTo(last);
      await tester.pump();
      if (cancelKind == 'pointer') {
        await gesture.cancel();
      }
      if (cancelKind == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        await gesture.up();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      if (cancelKind == 'outside') {
        await gesture.moveTo(last - const Offset(0, 150));
        await gesture.up();
      }
      if (cancelKind == 'resize') {
        tester.view.physicalSize = const Size(900, 600);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pump();
        await gesture.up();
      }
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(
        tester
            .getCenter(find.byKey(const Key('navigation-glass-indicator')))
            .dx,
        closeTo(
          tester.getCenter(find.byKey(const Key('navigation-tab-0'))).dx,
          .01,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'main pager stays still until release, then settles to the chosen page',
    (tester) async {
      final selected = ValueNotifier<int>(0),
          progress = ValueNotifier<double>(0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (context, value, _) => Column(
                children: [
                  Expanded(
                    child: SwipePages(
                      index: value,
                      onChanged: (i) => selected.value = i,
                      onProgress: (v) => progress.value = v,
                      children: List.generate(
                        4,
                        (i) => Center(child: Text('page$i')),
                      ),
                    ),
                  ),
                  GlassNavigation(
                    index: value,
                    progress: progress,
                    onChanged: (i) => selected.value = i,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final start = tester.getCenter(find.byKey(const Key('navigation-tab-0')));
      final end = tester.getCenter(find.byKey(const Key('navigation-tab-3')));
      final pager = tester.widget<PageView>(find.byType(PageView)).controller!;
      final gesture = await tester.startGesture(start);
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 180));
      await gesture.moveTo(end);
      await tester.pump();
      expect(pager.page, 0);
      expect(selected.value, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selected.value, 3);
      expect(pager.page, 3);
      expect(
        tester
            .getCenter(find.byKey(const Key('navigation-glass-indicator')))
            .dx,
        closeTo(end.dx, .01),
      );
      await tester.pumpWidget(const SizedBox());
      selected.dispose();
      progress.dispose();
    },
  );
}
