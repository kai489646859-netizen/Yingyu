import 'package:flutter/widgets.dart';

/// Text subtitle sizes use logical screen dimensions, independent of the
/// encoded video resolution, letterboxing and the device pixel ratio.
double subtitleFontSize(Size viewport, double scale) =>
    (viewport.shortestSide * .045).clamp(18.0, 32.0) * scale.clamp(.6, 2.0);

class SubtitleSizeScope extends InheritedWidget {
  const SubtitleSizeScope({
    super.key,
    required this.scale,
    required super.child,
  });
  final double scale;
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SubtitleSizeScope>()?.scale ??
      1;
  @override
  bool updateShouldNotify(SubtitleSizeScope oldWidget) =>
      scale != oldWidget.scale;
}
