import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/poster_motion.dart';
import 'poster_opacity.dart';

void main() {
  setUp(
    () => VisibilityDetectorController.instance.updateInterval = Duration.zero,
  );
  for (final axis in Axis.values) {
    for (final cache in [0.0, 400.0]) {
      testWidgets('$axis cards stay opaque at both edges with cache=$cache', (
        tester,
      ) async {
        final scroll = ScrollController();
        Widget page() => MaterialApp(
          home: Center(
            child: SizedBox(
              width: 360,
              height: 360,
              child: PosterMotionScope(
                child: ListView.builder(
                  controller: scroll,
                  scrollDirection: axis,
                  scrollCacheExtent: ScrollCacheExtent.pixels(cache),
                  itemExtent: 120,
                  itemCount: 20,
                  itemBuilder: (_, i) => PosterEntrance(
                    key: ValueKey('card-$i'),
                    id: '$i',
                    axis: axis,
                    child: ColoredBox(color: Colors.blue, child: Text('$i')),
                  ),
                ),
              ),
            ),
          ),
        );
        double opacity(int index) =>
            posterOpacity(tester, find.byKey(ValueKey('card-$index')));
        await tester.pumpWidget(page());
        await tester.pumpAndSettle();
        final gesture = await tester.startGesture(const Offset(400, 300));
        Offset movement(double value) =>
            axis == Axis.vertical ? Offset(0, value) : Offset(value, 0);
        await gesture.moveBy(movement(-20));
        await gesture.moveBy(movement(-80));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(
          opacity(3),
          1,
          reason: 'new bottom/right card stays fully visible',
        );
        expect(opacity(2), 1, reason: 'already visible card stays still');
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          opacity(0),
          1,
          reason: 'top/left departing card stays fully visible',
        );
        expect(opacity(2), 1);
        await tester.pump(const Duration(milliseconds: 230));
        await gesture.moveBy(movement(-80));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 230));
        final departing = opacity(1);
        expect(departing, 1);
        await gesture.moveBy(movement(80));
        await tester.pump();
        expect(
          opacity(1),
          departing,
          reason: 'reversing an exit has no opacity jump',
        );
        await tester.pump();
        await tester.pump();
        expect(
          opacity(0),
          1,
          reason: 'returning top/left card also stays fully visible',
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(
          opacity(3),
          1,
          reason: 'bottom/right departing card stays fully visible',
        );
        expect(opacity(2), 1);
        await tester.pump(const Duration(milliseconds: 230));
        expect(opacity(1), 1);
        await gesture.up();
        await tester.pumpWidget(page());
        await tester.pump();
        expect(
          opacity(0),
          1,
          reason: 'visible metadata rebuild does not replay animation',
        );
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('late image arrival never starts motion without scrolling', (
    tester,
  ) async {
    late BuildContext imageContext;
    await tester.pumpWidget(
      MaterialApp(
        home: PosterMotionScope(
          child: PosterEntrance(
            id: 'late',
            child: Builder(
              builder: (context) {
                imageContext = context;
                return const Text('image');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    double opacity() => posterOpacity(tester, find.byType(PosterEntrance));
    await tester.pump(const Duration(seconds: 2));
    expect(
      opacity(),
      1,
      reason: 'a loading placeholder is immediately visible',
    );
    const PosterImageStatus(ready: true).dispatch(imageContext);
    await tester.pump();
    expect(opacity(), 1);
    await tester.pump(const Duration(milliseconds: 230));
    const PosterImageStatus(ready: true).dispatch(imageContext);
    await tester.pump();
    expect(opacity(), 1);
    await tester.pumpWidget(const SizedBox());
  });
}
