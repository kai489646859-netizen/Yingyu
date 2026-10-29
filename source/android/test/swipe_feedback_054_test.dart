import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/swipe_pages.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'both edges resist, release and accept another drag reduced=$reduced',
      (tester) async {
        final selected = ValueNotifier(0);
        await tester.pumpWidget(
          MaterialApp(
            home: ValueListenableBuilder<int>(
              valueListenable: selected,
              builder: (_, index, _) => SwipePages(
                index: index,
                reducedMotion: reduced,
                onChanged: (v) => selected.value = v,
                children: [
                  for (var i = 0; i < 4; i++)
                    ColoredBox(
                      color: Colors.white,
                      child: Center(child: Text('Page $i')),
                    ),
                ],
              ),
            ),
          ),
        );
        double shift() => tester
            .widget<Transform>(find.byKey(const Key('page-edge-feedback')))
            .transform
            .storage[12];
        for (final side in [0, 3]) {
          selected.value = side;
          await tester.pumpAndSettle();
          final drag = await tester.startGesture(const Offset(400, 200));
          await drag.moveBy(Offset(side == 0 ? 200 : -200, 0));
          await tester.pump();
          expect(shift().abs(), allOf(greaterThan(1), lessThan(52)));
          expect(shift().sign, side == 0 ? 1 : -1);
          expect(selected.value, side);
          await drag.up();
          await tester.pumpAndSettle();
          expect(shift(), 0);
          await tester.dragFrom(
            const Offset(400, 200),
            Offset(side == 0 ? -250 : 250, 0),
          );
          await tester.pumpAndSettle();
          expect(selected.value, side == 0 ? 1 : 2);
        }
        await tester.pumpWidget(const SizedBox());
        selected.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('a quick second swipe during snap uses the committed destination', (
    tester,
  ) async {
    final selected = ValueNotifier(0);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<int>(
          valueListenable: selected,
          builder: (_, index, _) => SwipePages(
            index: index,
            onChanged: (v) => selected.value = v,
            children: [
              for (var i = 0; i < 4; i++)
                ColoredBox(color: Colors.white, child: Text('Page $i')),
            ],
          ),
        ),
      ),
    );
    await tester.dragFrom(const Offset(650, 200), const Offset(-200, 0));
    await tester.pump();
    expect(selected.value, 1);
    await tester.dragFrom(const Offset(650, 200), const Offset(-200, 0));
    await tester.pump();
    expect(selected.value, 2);
    await tester.pumpAndSettle();
    expect(tester.widget<PageView>(find.byType(PageView)).controller!.page, 2);
    await tester.dragFrom(const Offset(250, 200), const Offset(220, 0));
    await tester.pumpAndSettle();
    expect(selected.value, 1);
    // A vertical/diagonal gesture is rejected, but must not poison the next one.
    await tester.dragFrom(const Offset(250, 200), const Offset(60, 120));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(650, 200), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(selected.value, 2);
    await tester.pumpWidget(const SizedBox());
    selected.dispose();
    expect(tester.takeException(), isNull);
  });
}
