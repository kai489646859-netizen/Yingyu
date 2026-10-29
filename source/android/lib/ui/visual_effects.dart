import 'package:flutter/widgets.dart';

// Compatibility wrappers for shared callers and archived source comparisons.
// The liquid-glass presentation and its settings entry have been retired.
bool liquidGlassOf(BuildContext context) => false;

enum GlassRole { panel, dock, control }

class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    super.key,
    required this.child,
    this.radius = 24,
    this.overVideo = false,
    this.enabled = true,
    this.role = GlassRole.panel,
  });
  final Widget child;
  final double radius;
  final bool overVideo, enabled;
  final GlassRole role;
  @override
  Widget build(BuildContext context) => child;
}

class GlassControlSkin extends StatelessWidget {
  const GlassControlSkin({
    super.key,
    required this.child,
    this.radius = 22,
    this.selected = false,
    this.padding = EdgeInsets.zero,
  });
  final Widget child;
  final double radius;
  final bool selected;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => child;
}

class AppVisualBackdrop extends StatelessWidget {
  const AppVisualBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const Key('liquid-glass-backdrop'),
    decoration: const BoxDecoration(),
    child: child,
  );
}
