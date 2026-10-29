import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/swipe_pages.dart';
import 'package:yingyu/ui/style.dart';

void main() {
  for (final programmatic in [false, true]) {
    testWidgets(
      'vertical scrolling works during ${programmatic ? 'button' : 'swipe'} transition and dock tracks each frame',
      (tester) async {
        final index = ValueNotifier(0);
        final progress = ValueNotifier<double>(0);
        final scrolls = List.generate(4, (_) => ScrollController());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<int>(
                valueListenable: index,
                builder: (_, selected, _) => Column(
                  children: [
                    Expanded(
                      child: SwipePages(
                        index: selected,
                        onChanged: (v) => index.value = v,
                        onProgress: (v) => progress.value = v,
                        children: [
                          for (var i = 0; i < 4; i++)
                            ListView.builder(
                              key: ValueKey('list-$i'),
                              controller: scrolls[i],
                              itemExtent: 70,
                              itemCount: 100,
                              itemBuilder: (_, row) => Text('Page $i row $row'),
                            ),
                        ],
                      ),
                    ),
                    GlassNavigation(
                      index: selected,
                      onChanged: (v) => index.value = v,
                      progress: progress,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final pager = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        void synced() {
          final indicator = tester.getRect(
            find.byKey(const Key('navigation-glass-indicator')),
          );
          final first = tester.getRect(
            find.byKey(const ValueKey('navigation-tab-0')),
          );
          expect(
            indicator.left,
            closeTo(first.left + first.width * pager.page!, .1),
          );
        }

        if (programmatic) {
          await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
        } else {
          final gesture = await tester.startGesture(const Offset(730, 230));
          await gesture.moveBy(const Offset(-480, 0));
          await tester.pump(const Duration(milliseconds: 16));
          synced();
          expect(index.value, 0);
          await gesture.up();
          await tester.pump();
          expect(index.value, 1);
        }
        expect(pager.page, allOf(greaterThan(.5), lessThan(1)));
        synced();
        final vertical = await tester.startGesture(const Offset(690, 410));
        await vertical.moveBy(const Offset(-4, -45));
        await tester.pump(const Duration(milliseconds: 16));
        await vertical.moveBy(const Offset(3, -85));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          pager.page,
          lessThan(1),
          reason: 'test while the page is still moving',
        );
        expect(scrolls[1].offset, greaterThan(40));
        synced();
        await vertical.up();
        await tester.pumpAndSettle();
        expect(index.value, 1);
        expect(pager.page, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        for (final controller in scrolls) {
          controller.dispose();
        }
        index.dispose();
        progress.dispose();
      },
    );
  }
  testWidgets(
    'vertical and diagonal gestures never become page swipes midway',
    (tester) async {
      final changes = <int>[];
      final scroll = ScrollController(initialScrollOffset: 300);
      await tester.pumpWidget(
        MaterialApp(
          home: SwipePages(
            index: 0,
            onChanged: changes.add,
            children: [
              ListView.builder(
                controller: scroll,
                itemExtent: 70,
                itemCount: 100,
                itemBuilder: (_, i) => Text('row $i'),
              ),
              const Text('next'),
            ],
          ),
        ),
      );
      final pager = tester.widget<PageView>(find.byType(PageView)).controller!;
      for (final delta in [
        const Offset(-28, -45),
        const Offset(7, -34),
        const Offset(-20, -16),
      ]) {
        final gesture = await tester.startGesture(const Offset(670, 380));
        await gesture.moveBy(delta);
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.moveBy(const Offset(-260, -100));
        await tester.pump(const Duration(milliseconds: 16));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(pager.page, 0);
      }
      expect(changes, isEmpty);
      expect(scroll.offset, greaterThan(300));
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );
}
