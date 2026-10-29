import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:yingyu/core/appearance.dart';

bool liquidGlassOf(BuildContext context) =>
    Theme.of(context).extension<VisualStyleTheme>()?.style ==
    VisualStyle.liquidGlass;

/// Shared material for controls and panels, confined to their bounds rather
/// than installed on the video renderer or posters. Standard quality uses the pinned renderer's
/// lightweight shader, with its built-in fallback when shaders are unavailable.
class AppGlassSurface extends StatelessWidget {
  const AppGlassSurface({
    super.key,
    required this.child,
    this.radius = 24,
    this.overVideo = false,
    this.enabled = true,
  });
  final Widget child;
  final double radius;
  final bool overVideo, enabled;

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
    return AdaptiveGlass(
      key: const Key('liquid-glass-surface'),
      shape: LiquidRoundedRectangle(borderRadius: radius),
      quality: GlassQuality.standard,
      platformViewBackdrop: overVideo,
      allowElevation: false,
      settings: LiquidGlassSettings(
        glassColor: theme.colorScheme.primary.withValues(alpha: .06),
        backerColor: (dark ? const Color(0xFF202329) : Colors.white).withValues(
          alpha: overVideo ? .78 : .72,
        ),
        blur: overVideo ? 5 : 8,
        thickness: 18,
        refractiveIndex: 1.12,
        chromaticAberration: 0,
        saturation: 1,
        lightIntensity: .55,
        shadowElevation: 0,
      ),
      child: child,
    );
  }
}

/// A static backdrop gives the global glass material depth without a full-page
/// blur or an animation that would continue while playing or in the background.
class AppVisualBackdrop extends StatelessWidget {
  const AppVisualBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (!liquidGlassOf(context)) return child;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = dark ? const Color(0xFF121419) : const Color(0xFFF2F2F7);
    final accent = theme.colorScheme.primary;
    return DecoratedBox(
      key: const Key('liquid-glass-backdrop'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(accent.withValues(alpha: dark ? .16 : .14), base),
            base,
            Color.alphaBlend(accent.withValues(alpha: .09), base),
          ],
          stops: const [0, .55, 1],
        ),
      ),
      child: child,
    );
  }
}
