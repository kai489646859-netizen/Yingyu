// Presentation adapted from NipaPlay-Reload v1.11.9 (MIT).
// See dependencies/visual-reference for the pinned sources and license.
import 'dart:ui' show ImageFilter;
import 'package:flutter/foundation.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/appearance.dart';
import 'poster_press.dart';
import 'device_layout.dart';
import 'visual_effects.dart';
export 'visual_effects.dart';
export 'device_layout.dart';

Color accentColor(BuildContext context) =>
    Theme.of(context).colorScheme.primary;
ThemeData playerTheme(BuildContext context) {
  final theme = appTheme(
    Brightness.dark,
    accentChoice:
        Theme.of(context).extension<AccentTheme>()?.choice ?? AppAccent.lilac,
    visualStyle:
        Theme.of(context).extension<VisualStyleTheme>()?.style ??
        VisualStyle.traditional,
  );
  if (!liquidGlassOf(context)) return theme;
  const shadows = [
    Shadow(color: Color(0xCC000000), blurRadius: 2, offset: Offset(0, 1)),
  ];
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      bodyMedium: theme.textTheme.bodyMedium?.copyWith(shadows: shadows),
      bodySmall: theme.textTheme.bodySmall?.copyWith(shadows: shadows),
      titleMedium: theme.textTheme.titleMedium?.copyWith(shadows: shadows),
    ),
  );
}

/// One translucent background layer for player panels; content stays opaque.
Color playerPanelColor(BuildContext context) => Color.alphaBlend(
  accentColor(context).withValues(alpha: .12),
  const Color(0xFF19191D),
).withValues(alpha: .8);
bool wideLayout(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= 600 && size.width > size.height;
}

Color labelColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface;
Color secondaryColor(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;
Color groupedColor(BuildContext context) =>
    Theme.of(context).scaffoldBackgroundColor;

/// The parent of a grouped card (page, sheet or desktop panel).
class GroupedBackground extends InheritedWidget {
  const GroupedBackground({
    super.key,
    required this.color,
    this.transparentCards = false,
    required super.child,
  });
  final Color color;
  final bool transparentCards;
  static Color of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GroupedBackground>()?.color ??
      groupedColor(context);
  static bool transparentCardsOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<GroupedBackground>()
          ?.transparentCards ??
      false;
  @override
  bool updateShouldNotify(GroupedBackground oldWidget) =>
      color != oldWidget.color ||
      transparentCards != oldWidget.transparentCards;
}

double pageInset(double width) => (width * .027).clamp(28.0, 42.0);
double contentInset(BuildContext context) =>
    phoneLayout(context) ? 16 : pageInset(MediaQuery.sizeOf(context).width);

class DockInset extends InheritedWidget {
  const DockInset({super.key, required this.bottom, required super.child});
  final double bottom;
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DockInset>()?.bottom ?? 0;
  @override
  bool updateShouldNotify(DockInset oldWidget) => bottom != oldWidget.bottom;
}

double browseBottomSpace(BuildContext context, {double wide = 24}) {
  final original = phoneLayout(context)
      ? 24
      : wideLayout(context)
      ? wide
      : 112;
  final dock = DockInset.of(context);
  return dock > original ? dock : original.toDouble();
}

double pageHeadingSize(BuildContext context) => phoneLayout(context)
    ? 21
    : MediaQuery.orientationOf(context) == Orientation.portrait
    ? 26
    : 30;

/// Keep page geometry fixed while clipping the part covered by the IME. This
/// also lets visibility-based image loading exclude the covered posters.
class KeyboardCoveredArea extends StatelessWidget {
  const KeyboardCoveredArea({
    super.key,
    required this.child,
    this.bottomSpace = 0,
  });
  final Widget child;
  final double bottomSpace;
  @override
  Widget build(BuildContext context) => ClipRect(
    clipper: _KeyboardClip(
      (MediaQuery.viewInsetsOf(context).bottom - bottomSpace).clamp(
        0.0,
        double.infinity,
      ),
    ),
    child: child,
  );
}

class _KeyboardClip extends CustomClipper<Rect> {
  const _KeyboardClip(this.covered);
  final double covered;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    0,
    0,
    size.width,
    (size.height - covered).clamp(0.0, size.height),
  );
  @override
  bool shouldReclip(_KeyboardClip oldClipper) => covered != oldClipper.covered;
}

ThemeData appTheme(
  Brightness brightness, {
  AppAccent accentChoice = AppAccent.lilac,
  VisualStyle visualStyle = VisualStyle.traditional,
}) {
  visualStyle = VisualStyle.traditional;
  final dark = brightness == Brightness.dark;
  final accent = visualStyle == VisualStyle.liquidGlass && !dark
      ? Color.alphaBlend(
          const Color(0x14000000),
          accentChoice.color(brightness),
        )
      : accentChoice.color(brightness);
  final background = Color.alphaBlend(
    accent.withValues(alpha: dark ? .055 : .045),
    dark ? const Color(0xFF121419) : const Color(0xFFF2F2F7),
  );
  final surface = Color.alphaBlend(
    accent.withValues(alpha: dark ? .035 : .025),
    dark ? const Color(0xFF202329) : Colors.white,
  );
  final foreground = dark ? Colors.white : Colors.black;
  final secondary = dark ? const Color(0xFFC7C7CC) : const Color(0xFF5B5B63);
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        onPrimary: dark ? Colors.black : Colors.white,
        surface: surface,
        onSurface: foreground,
        onSurfaceVariant: secondary,
        surfaceContainerHighest: dark
            ? const Color(0xFF2C2C2E)
            : const Color(0xFFE5E5EA),
        outlineVariant: dark
            ? const Color(0x33FFFFFF)
            : const Color(0x1F000000),
      );
  return ThemeData(
    extensions: [AccentTheme(accentChoice), VisualStyleTheme(visualStyle)],
    useMaterial3: true,
    fontFamily: 'Roboto',
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: visualStyle == VisualStyle.liquidGlass
        ? Colors.transparent
        : background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: dark ? const Color(0x20FFFFFF) : const Color(0x18000000),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: accent,
      scaffoldBackgroundColor: visualStyle == VisualStyle.liquidGlass
          ? Colors.transparent
          : background,
      textTheme: CupertinoTextThemeData(
        textStyle: TextStyle(
          fontFamily: 'Roboto',
          color: foreground,
          fontSize: 17,
        ),
        primaryColor: accent,
      ),
    ),
    textTheme: TextTheme(
      headlineLarge: const TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
      titleMedium: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14, color: foreground),
      bodySmall: TextStyle(fontSize: 12, color: secondary),
    ),
    appBarTheme: AppBarTheme(
      actionsIconTheme: IconThemeData(color: accent),
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Roboto',
        color: foreground,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: .5),
    iconTheme: IconThemeData(color: foreground, size: 22),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: accent),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: dark
          ? const Color(0xFF454750)
          : const Color(0xFFD5D4DD),
      trackGap: 0,
      stopIndicatorRadius: 0,
    ),
  );
}

/// The scroll viewport covers the entire page, including the tablet gutters.
/// Only the content is inset; the empty margins still accept drag gestures.
class PageList extends StatelessWidget {
  const PageList({
    super.key,
    required this.children,
    this.storageKey,
    this.bottom = 0,
    this.header,
  });
  final List<Widget> children;
  final Key? storageKey;
  final double bottom;
  final Widget? header;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final inset = ((bounds.maxWidth - 820) / 2).clamp(0.0, double.infinity);
      final dock = DockInset.of(context);
      final list = ListView(
        key: storageKey,
        padding: EdgeInsets.fromLTRB(
          inset,
          0,
          inset,
          dock > bottom ? dock : bottom,
        ),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        children: children,
      );
      return header == null
          ? list
          : Column(
              children: [
                header!,
                Expanded(child: list),
              ],
            );
    },
  );
}

/// A compact action shared by the fixed headings of the main pages.
class PageHeaderAction extends InheritedWidget {
  const PageHeaderAction({
    super.key,
    required this.action,
    this.notice,
    required super.child,
  });
  final Widget? action;
  final Widget? notice;
  @override
  bool updateShouldNotify(PageHeaderAction oldWidget) =>
      action != oldWidget.action || notice != oldWidget.notice;
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(
    this.title, {
    super.key,
    this.subtitle,
    this.trailing,
    this.titleWidget,
    this.showPageAction = true,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? titleWidget;
  final bool showPageAction;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: EdgeInsets.fromLTRB(
          contentInset(context),
          phoneValue(context, 2, 8),
          phoneValue(context, 12, 20),
          phoneValue(context, 4, 10),
        ),
        child: Row(
          children: [
            Expanded(
              child:
                  titleWidget ??
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: labelColor(context),
                      fontSize: pageHeadingSize(context),
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
            ),
            ?trailing,
            if (showPageAction)
              ?context
                  .dependOnInheritedWidgetOfExactType<PageHeaderAction>()
                  ?.action,
          ],
        ),
      ),
      ?context.dependOnInheritedWidgetOfExactType<PageHeaderAction>()?.notice,
    ],
  );
}

class GlassNavigation extends StatelessWidget {
  const GlassNavigation({
    super.key,
    required this.index,
    required this.onChanged,
    this.reducedMotion = false,
    this.progress,
    this.onSearch,
  });
  final VoidCallback? onSearch;
  final int index;
  final ValueChanged<int> onChanged;
  final bool reducedMotion;
  final ValueListenable<double>? progress;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = accentColor(context);
    final reduce = reducedMotion || MediaQuery.disableAnimationsOf(context);
    const labels = ['首页', '媒体库', '设置', '账户'];
    const icons = [
      CupertinoIcons.house_fill,
      CupertinoIcons.rectangle_stack_fill,
      CupertinoIcons.settings_solid,
      CupertinoIcons.person_fill,
    ];
    // Only the indicator listens to page pixels. The buttons, blur, text and
    // decoration stay outside the per-frame rebuild during swipes.
    final navigation = AppGlassSurface(
      radius: phoneValue(context, 32, 34),
      child: ClipRRect(
        key: const Key('phone-navigation'),
        borderRadius: BorderRadius.circular(phoneValue(context, 32, 34)),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: liquidGlassOf(context) ? 0 : 16,
            sigmaY: liquidGlassOf(context) ? 0 : 16,
          ),
          child: Container(
            height: phoneValue(context, 56, 68),
            decoration: BoxDecoration(
              color: liquidGlassOf(context)
                  ? Colors.transparent
                  : Color.alphaBlend(
                      accent.withValues(alpha: .06),
                      dark ? const Color(0xCC19191E) : const Color(0xCCEDEDF2),
                    ),
              borderRadius: BorderRadius.circular(phoneValue(context, 32, 34)),
              border: Border.all(
                color: accent.withValues(alpha: .18),
                width: .6,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth / 4;
                  final indicator = IgnorePointer(
                    child: RepaintBoundary(
                      child: DecoratedBox(
                        key: const Key('navigation-glass-indicator'),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            phoneValue(context, 27, 29),
                          ),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              accent.withValues(alpha: dark ? .34 : .22),
                              accent.withValues(alpha: dark ? .20 : .12),
                            ],
                          ),
                          border: Border.all(
                            color: accent.withValues(alpha: .30),
                            width: .8,
                          ),
                        ),
                      ),
                    ),
                  );
                  return Stack(
                    children: [
                      if (progress != null)
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: width,
                          child: ValueListenableBuilder<double>(
                            valueListenable: progress!,
                            child: indicator,
                            builder: (context, page, child) =>
                                Transform.translate(
                                  offset: Offset(page.clamp(0, 3) * width, 0),
                                  child: child,
                                ),
                          ),
                        )
                      else
                        AnimatedPositioned(
                          duration: reduce
                              ? Duration.zero
                              : const Duration(milliseconds: 340),
                          curve: Curves.easeInOutCubic,
                          left: index * width,
                          top: 0,
                          bottom: 0,
                          width: width,
                          child: indicator,
                        ),
                      Row(
                        children: [
                          for (var i = 0; i < 4; i++)
                            Expanded(
                              child: Semantics(
                                selected: index == i,
                                button: true,
                                child: CupertinoButton(
                                  key: ValueKey('navigation-tab-$i'),
                                  padding: EdgeInsets.zero,
                                  onPressed: () => onChanged(i),
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        icons[i],
                                        size: phoneValue(context, 21, 26),
                                        color: index == i
                                            ? accent
                                            : secondaryColor(context),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        labels[i],
                                        textScaler: TextScaler.noScaling,
                                        style: TextStyle(
                                          fontSize: phoneValue(context, 11, 13),
                                          fontWeight: index == i
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: index == i
                                              ? accent
                                              : secondaryColor(context),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    if (!phoneLayout(context) || onSearch == null) return navigation;
    return Row(
      children: [
        Expanded(child: navigation),
        const SizedBox(width: 10),
        AppGlassSurface(
          radius: 28,
          child: ClipOval(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: liquidGlassOf(context) ? 0 : 16,
                sigmaY: liquidGlassOf(context) ? 0 : 16,
              ),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: liquidGlassOf(context)
                      ? Colors.transparent
                      : dark
                      ? const Color(0xCC25252B)
                      : const Color(0xE6F5F5F7),
                  border: Border.all(
                    color: accent.withValues(alpha: .18),
                    width: .6,
                  ),
                ),
                child: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: onSearch,
                  child: Icon(
                    CupertinoIcons.search,
                    color: labelColor(context),
                    semanticLabel: '搜索影片或演员',
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.icon, {super.key, this.destructive = false});
  final IconData icon;
  final bool destructive;
  @override
  Widget build(BuildContext context) => Container(
    width: phoneValue(context, 26, 28),
    height: phoneValue(context, 26, 28),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: destructive
          ? Theme.of(context).colorScheme.error
          : accentColor(context),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Icon(
      icon,
      size: 18,
      color: destructive
          ? Theme.of(context).colorScheme.onError
          : Theme.of(context).colorScheme.onPrimary,
    ),
  );
}

class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    this.title,
    this.footer,
    required this.children,
  });
  final String? title, footer;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      phoneValue(context, 16, 20),
      8,
      phoneValue(context, 16, 20),
      phoneValue(context, 8, 12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
            child: Text(
              title!,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: accentColor(context),
              ),
            ),
          ),
        // Paint the whole cached rectangle, including the rounded cut-outs.
        // Route transitions must not rely on transparent corner pixels from
        // an earlier composited frame (also used by account cards).
        ColoredBox(
          color:
              liquidGlassOf(context) ||
                  GroupedBackground.transparentCardsOf(context)
              ? Colors.transparent
              : GroupedBackground.of(context),
          child: AppGlassSurface(
            enabled: !GroupedBackground.transparentCardsOf(context),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: ColoredBox(
                color:
                    liquidGlassOf(context) ||
                        GroupedBackground.transparentCardsOf(context)
                    ? Colors.transparent
                    : Theme.of(context).colorScheme.surface,
                child: Column(
                  children: [
                    for (var i = 0; i < children.length; i++) ...[
                      if (i > 0) const Divider(height: .5, indent: 20),
                      children[i],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
            child: Text(
              footer!,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: secondaryColor(context),
              ),
            ),
          ),
      ],
    ),
  );
}

class SettingsRow extends StatelessWidget {
  const SettingsRow(
    this.title, {
    super.key,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.selected = false,
    this.showDisclosure = true,
    this.singleLine = false,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final bool selected, showDisclosure, singleLine;
  @override
  Widget build(BuildContext context) {
    return PosterPressFeedback(
      active: onTap != null,
      child: CupertinoButton(
        pressedOpacity: 1,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: phoneValue(context, 14, 20),
            vertical: phoneValue(context, 10, 14),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                SettingsIcon(icon!, destructive: destructive),
                SizedBox(width: phoneValue(context, 10, 14)),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: singleLine ? 1 : null,
                      overflow: singleLine ? TextOverflow.ellipsis : null,
                      style: TextStyle(
                        fontSize: phoneValue(context, 15, 16),
                        color: destructive
                            ? Theme.of(context).colorScheme.error
                            : selected
                            ? accentColor(context)
                            : labelColor(context),
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 5),
                      Text(
                        subtitle!,
                        maxLines: singleLine ? 1 : null,
                        overflow: singleLine ? TextOverflow.ellipsis : null,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: selected
                              ? accentColor(context)
                              : secondaryColor(context),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                trailing!,
              ] else if (onTap != null && showDisclosure) ...[
                const SizedBox(width: 12),
                Icon(
                  CupertinoIcons.chevron_forward,
                  size: 15,
                  color: secondaryColor(context),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class MessagePanel extends StatelessWidget {
  const MessagePanel(
    this.message, {
    super.key,
    this.retry,
    this.busy = false,
    this.icon = CupertinoIcons.exclamationmark_circle,
  });
  final String message;
  final VoidCallback? retry;
  final bool busy;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const CupertinoActivityIndicator(radius: 12)
          else
            Icon(icon, size: 48, color: secondaryColor(context)),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: secondaryColor(context)),
          ),
          if (retry != null)
            CupertinoButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );
}
