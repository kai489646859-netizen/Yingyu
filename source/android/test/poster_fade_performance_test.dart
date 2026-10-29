import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/poster_motion.dart';
import 'poster_opacity.dart';

class PaintCounter extends SingleChildRenderObjectWidget {
  const PaintCounter({super.key, required this.onPaint, required super.child});
  final VoidCallback onPaint;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _PaintCounter(onPaint);
}

class _PaintCounter extends RenderProxyBox {
  _PaintCounter(this.onPaint);
  final VoidCallback onPaint;
  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}

void main() {
  setUp(
    () => VisibilityDetectorController.instance.updateInterval = Duration.zero,
  );
  for (final axis in Axis.values) {
    for (final checkWork in [false, true]) {
      testWidgets(
        '$axis ${checkWork ? 'static cards create no per-frame animation work' : 'edge crossings have no animation'}',
        (tester) async {
          final paints = <int, int>{};
          await tester.pumpWidget(
            MaterialApp(
              home: Center(
                child: SizedBox(
                  width: 360,
                  height: 360,
                  child: PosterMotionScope(
                    child: ListView.builder(
                      itemExtent: 120,
                      itemCount: 30,
                      scrollDirection: axis,
                      itemBuilder: (_, i) => PosterEntrance(
                        key: ValueKey('card-$i'),
                        id: '$i',
                        axis: axis,
                        child: PaintCounter(
                          onPaint: () =>
                              paints.update(i, (n) => n + 1, ifAbsent: () => 1),
                          child: ColoredBox(
                            key: ValueKey('art-$i'),
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final gesture = await tester.startGesture(const Offset(400, 300));
          Offset movement(double value) =>
              axis == Axis.vertical ? Offset(0, value) : Offset(value, 0);
          await gesture.moveBy(movement(-20));
          await gesture.moveBy(movement(-80));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          double alpha(int i) =>
              posterOpacity(tester, find.byKey(ValueKey('card-$i')));
          final entered = alpha(3), leaving = alpha(0);
          expect(
            find.descendant(
              of: find.byType(PosterEntrance),
              matching: find.byType(FadeTransition),
            ),
            findsNothing,
          );
          expect(
            find.descendant(
              of: find.byType(PosterEntrance),
              matching: find.byType(Opacity),
            ),
            findsNothing,
          );
          expect(entered, 1);
          expect(leaving, 1);
          expect(alpha(2), 1);
          if (checkWork) {
            var rebuilds = 0;
            final previous = debugOnRebuildDirtyWidget;
            debugOnRebuildDirtyWidget = (element, builtOnce) {
              previous?.call(element, builtOnce);
              if (element.findAncestorWidgetOfExactType<PosterEntrance>() !=
                  null) {
                rebuilds++;
              }
            };
            addTearDown(() => debugOnRebuildDirtyWidget = previous);
            final paintCounts = Map.of(paints);
            for (var i = 0; i < 6; i++) {
              await tester.pump(const Duration(milliseconds: 16));
            }
            final result = <String, Object>{
              'axis': axis.name,
              'observed_idle_frames': 6,
              'poster_subtree_rebuilds': rebuilds,
              'poster_content_repaints': paints.entries.fold<int>(
                0,
                (n, e) => n + e.value - (paintCounts[e.key] ?? 0),
              ),
            };
            // This is an operation count under the widget test renderer, not a
            // device frame-rate or GPU benchmark.
            debugPrint('STATIC_POSTER_WORK $result');
            expect(alpha(3), entered);
            expect(alpha(0), leaving);
            expect(
              rebuilds,
              0,
              reason: 'opacity ticks must not rebuild card wrappers',
            );
            expect(
              paints,
              paintCounts,
              reason: 'reuse the card layer during alpha-only ticks',
            );
            debugOnRebuildDirtyWidget = previous;
          } else {
            for (var frame = 0; frame < 6; frame++) {
              for (final i in [0, 2, 3]) {
                expect(
                  tester.getTopLeft(find.byKey(ValueKey('art-$i'))),
                  tester.getTopLeft(find.byKey(ValueKey('card-$i'))),
                  reason:
                      'fade must never displace the artwork or its tap area',
                );
              }
              await tester.pump(const Duration(milliseconds: 16));
            }
          }
          await gesture.up();
          await tester.pumpWidget(const SizedBox());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
