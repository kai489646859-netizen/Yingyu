import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/poster_motion.dart';
import 'poster_opacity.dart';

double opacity(WidgetTester tester, String id) =>
    posterOpacity(tester, find.byKey(ValueKey(id)));

Widget card(String id, Axis axis, {bool active = true}) => PosterEntrance(
  key: ValueKey(id),
  id: id,
  axis: axis,
  active: active,
  child: ColoredBox(color: Colors.blue, child: Text(id)),
);

void main() {
  setUp(
    () => VisibilityDetectorController.instance.updateInterval = Duration.zero,
  );
  for (final axis in Axis.values) {
    testWidgets('$axis initial page has no entrance without a user scroll', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: PosterMotionScope(
            child: ListView(
              scrollDirection: axis,
              itemExtent: 120,
              children: [card('a', axis), card('b', axis)],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(opacity(tester, 'a'), 1);
      expect(opacity(tester, 'b'), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$axis tab return stays still', (tester) async {
      late StateSetter update;
      var active = true;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (_, set) {
              update = set;
              return Offstage(
                offstage: !active,
                child: TickerMode(
                  enabled: active,
                  child: PosterMotionScope(
                    child: ListView(
                      scrollDirection: axis,
                      itemExtent: 120,
                      children: [card('return', axis, active: active)],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      update(() => active = false);
      await tester.pump();
      await tester.pump();
      update(() => active = true);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(opacity(tester, 'return'), 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('$axis programmatic reposition does not animate posters', (
      tester,
    ) async {
      final controller = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 240,
              height: 240,
              child: PosterMotionScope(
                child: ListView.builder(
                  controller: controller,
                  scrollDirection: axis,
                  itemExtent: 120,
                  itemCount: 12,
                  itemBuilder: (_, i) => card('jump-$i', axis),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(80);
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(opacity(tester, 'jump-2'), 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  }

  testWidgets('vertical homepage scrolling cannot trigger a horizontal rail', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 300,
            child: PosterMotionScope(
              child: ListView(
                children: [
                  const SizedBox(height: 340),
                  SizedBox(
                    height: 180,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      itemExtent: 120,
                      children: [
                        card('rail-a', Axis.horizontal),
                        card('rail-b', Axis.horizontal),
                      ],
                    ),
                  ),
                  const SizedBox(height: 600),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(0, -160));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(opacity(tester, 'rail-a'), 1);
    expect(opacity(tester, 'rail-b'), 1);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
