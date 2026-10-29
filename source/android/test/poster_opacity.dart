import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Read the actual outer alpha in either the delivered Opacity implementation
// or the render-only FadeTransition. The same assertions can test both builds.
double posterOpacity(WidgetTester tester, Finder card) {
  final nodes = find.descendant(
    of: card,
    matching: find.byWidgetPredicate(
      (widget) => widget is Opacity || widget is FadeTransition,
    ),
  );
  if (nodes.evaluate().isEmpty) return 1;
  final render = tester.renderObject(nodes.first);
  if (render is RenderAnimatedOpacity) return render.opacity.value;
  return (render as RenderOpacity).opacity;
}
