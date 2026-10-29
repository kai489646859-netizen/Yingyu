import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../core/appearance.dart';

bool liquidGlassOf(BuildContext context) =>
    Theme.of(context).extension<VisualStyleTheme>()?.style ==
    VisualStyle.liquidGlass;

enum GlassRole { panel, dock, control }

class _GlassLayer extends InheritedWidget {
  const _GlassLayer({required super.child});
  static bool contains(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_GlassLayer>() != null;
  @override
  bool updateShouldNotify(_GlassLayer oldWidget) => false;
}

/// Shared material for controls and panels, confined to their bounds rather
/// than installed on the video renderer or posters. UI lenses use the pinned
/// local compositor shader when supported, with its compatible fallback.
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
  Widget build(BuildContext context) {
    if (!enabled || !liquidGlassOf(context)) return child;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    if (MediaQuery.highContrastOf(context)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: ColoredBox(color: theme.colorScheme.surface, child: child),
      );
    }
    // A panel owns one optical layer. Its buttons and inner groups use a
    // painted material, avoiding stacked backdrop filters over the same pixels.
    if (_GlassLayer.contains(context)) {
      return GlassControlSkin(radius: radius, child: child);
    }
    final alpha = overVideo
        ? .08
        : switch (role) {
            GlassRole.dock => 0.0,
            GlassRole.control => .035,
            GlassRole.panel => dark ? .28 : .34,
          };
    final material = AdaptiveGlass(
      key: const Key('liquid-glass-surface'),
      shape: LiquidRoundedRectangle(borderRadius: radius),
      // The pinned premium path reads the clipped compositor backdrop directly;
      // unsupported engines fall back automatically. Video keeps its existing
      // live-compositor path, with a clear tint instead of a dense dark pad.
      quality: overVideo ? GlassQuality.standard : GlassQuality.premium,
      platformViewBackdrop: overVideo,
      allowElevation: false,
      settings: LiquidGlassSettings(
        glassColor: theme.colorScheme.primary.withValues(alpha: .025),
        backerColor: (dark ? const Color(0xFF202329) : Colors.white).withValues(
          alpha: alpha,
        ),
        blur: overVideo
            ? 2.5
            : role == GlassRole.panel
            ? 6
            : 3,
        thickness: role == GlassRole.panel ? 16 : 12,
        refractiveIndex: 1.14,
        chromaticAberration: 0,
        saturation: 1,
        lightIntensity: .55,
        ambientRim: 0,
        shadowElevation: 0,
      ),
      child: _GlassLayer(child: child),
    );
    // Do not paint a filled drop shadow behind the lens: its interior would
    // become another dark pad visible through the glass.
    return CustomPaint(
      foregroundPainter: _GlassRim(radius, dark, theme.colorScheme.primary),
      child: material,
    );
  }
}

/// Inner controls share their panel's optical layer, with an independent
/// highlight and theme tint. No extra blur or animation is created per button.
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
  Widget build(BuildContext context) {
    if (!liquidGlassOf(context)) return child;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              accent.withValues(alpha: selected ? .15 : .025),
              Colors.white.withValues(alpha: dark ? .12 : .36),
            ),
            accent.withValues(alpha: selected ? .17 : .045),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: dark ? .16 : .5),
          width: .65,
        ),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _GlassRim extends CustomPainter {
  const _GlassRim(this.radius, this.dark, this.tint);
  final double radius;
  final bool dark;
  final Color tint;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(.55);
    if (rect.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = .85
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: dark ? .38 : .85),
          Colors.white.withValues(alpha: .04),
          tint.withValues(alpha: .13),
          Colors.white.withValues(alpha: dark ? .22 : .62),
        ],
        stops: const [0, .42, .7, 1],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        Radius.circular((radius - .55).clamp(0, double.infinity)),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GlassRim oldDelegate) =>
      radius != oldDelegate.radius ||
      dark != oldDelegate.dark ||
      tint != oldDelegate.tint;
}

/// A static backdrop gives the global glass material depth without a full-page
/// blur or an animation that would continue while playing or in the background.
class AppVisualBackdrop extends StatelessWidget {
  const AppVisualBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final glass = liquidGlassOf(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = dark ? const Color(0xFF121419) : const Color(0xFFF2F2F7);
    final accent = theme.colorScheme.primary;
    return DecoratedBox(
      key: const Key('liquid-glass-backdrop'),
      decoration: glass
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    accent.withValues(alpha: dark ? .16 : .14),
                    base,
                  ),
                  base,
                  Color.alphaBlend(accent.withValues(alpha: .09), base),
                ],
                stops: const [0, .55, 1],
              ),
            )
          : const BoxDecoration(),
      child: child,
    );
  }
}
