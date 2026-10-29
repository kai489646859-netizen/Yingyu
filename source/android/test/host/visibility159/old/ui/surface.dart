// NipaPlay CupertinoBottomSheet / NipaplayWindow presentation (MIT).
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'poster.dart';
import 'detail_artwork_priority.dart';
import 'style.dart';
import 'menu_placement.dart';

Future<T?> showSurface<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool playerMenu = false,
  Rect? anchor,
  Rect? Function()? anchorProvider,
  bool toggleAnchor = false,
}) => Navigator.of(context).push<T>(
  _SurfaceRoute<T>(
    builder,
    playerMenu,
    playerMenu ? playerTheme(context) : Theme.of(context),
    anchor,
    anchorProvider,
    toggleAnchor,
  ),
);

class _SurfaceRoute<T> extends PopupRoute<T> {
  _SurfaceRoute(
    this.builder,
    this.playerMenu,
    this.theme,
    this.anchor,
    this.anchorProvider,
    this.toggleAnchor,
  );
  final WidgetBuilder builder;
  final bool playerMenu;
  final ThemeData theme;
  final Rect? anchor;
  final Rect? Function()? anchorProvider;
  final bool toggleAnchor;
  @override
  // Keep the video behind a player panel at its original level; another dark
  // scrim would reduce the requested twenty percent background transmission.
  Color get barrierColor =>
      playerMenu ? Colors.transparent : const Color(0x66000000);
  @override
  bool get barrierDismissible => true;
  @override
  String get barrierLabel => '关闭';
  @override
  Duration get transitionDuration =>
      Duration(milliseconds: playerMenu ? 240 : 300);
  @override
  Duration get reverseTransitionDuration =>
      Duration(milliseconds: playerMenu ? 170 : 300);
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Theme(
    data: theme,
    child: CupertinoTheme(
      // A Material Theme alone inherits an existing CupertinoTheme, which can
      // leave light-mode labels on a dark player panel. Override both together.
      data: MaterialBasedCupertinoThemeData(materialTheme: theme),
      child: toggleAnchor && playerMenu && anchor != null
          ? Stack(
              fit: StackFit.expand,
              children: [
                Builder(builder: builder),
                _PlayerMenuToggle(
                  anchor: anchor!,
                  anchorProvider: anchorProvider,
                ),
              ],
            )
          : Builder(builder: builder),
    ),
  );
  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    if (anchor != null) return FadeTransition(opacity: curved, child: child);
    if (wideLayout(context)) {
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(
            begin: playerMenu ? .95 : .8,
            end: 1,
          ).animate(curved),
          alignment: Alignment.center,
          child: child,
        ),
      );
    }
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }
}

/// Only while the panel is expanded, its original trigger becomes an explicit
/// dismiss target. Nothing is painted or passed through to playback gestures.
class _PlayerMenuToggle extends StatefulWidget {
  const _PlayerMenuToggle({required this.anchor, this.anchorProvider});
  final Rect anchor;
  final Rect? Function()? anchorProvider;
  @override
  State<_PlayerMenuToggle> createState() => _PlayerMenuToggleState();
}

class _PlayerMenuToggleState extends State<_PlayerMenuToggle> {
  Rect? tracked;
  Size? screen;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (screen != size) {
      screen = size;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final next = widget.anchorProvider?.call();
        if (next != null && tracked != next) setState(() => tracked = next);
      });
    }
    final rect = tracked ?? widget.anchor;
    return Positioned.fromRect(
      rect: rect,
      child: Semantics(
        label: '收起播放器菜单',
        button: true,
        child: GestureDetector(
          key: const Key('player-menu-toggle-close'),
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).pop(),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// Position a custom player panel using the invoking route's actual control.
class AnchoredSurface extends StatefulWidget {
  const AnchoredSurface({
    super.key,
    required this.width,
    required this.maxHeight,
    required this.child,
    required this.unanchored,
  });
  final double width, maxHeight;
  final Widget child;
  final Widget Function(Widget child) unanchored;
  @override
  State<AnchoredSurface> createState() => _AnchoredSurfaceState();
}

class _AnchoredSurfaceState extends State<AnchoredSurface> {
  Rect? trackedAnchor;
  Size? lastScreen;
  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    if (route is _SurfaceRoute &&
        route.anchorProvider != null &&
        lastScreen != screen) {
      lastScreen = screen;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final next = route.anchorProvider!();
        if (next != null && next != trackedAnchor) {
          setState(() => trackedAnchor = next);
        }
      });
    }
    final anchor =
        trackedAnchor ?? (route is _SurfaceRoute ? route.anchor : null);
    if (anchor == null) return widget.unanchored(widget.child);
    return CustomSingleChildLayout(
      delegate: MenuPlacement(
        anchor: anchor,
        width: widget.width,
        maxHeight: widget.maxHeight,
        safe: safe,
        gap: 4,
        alignRight: anchor.center.dx >= screen.width / 2,
        centerOnAnchor: true,
        forceAbove: true,
      ),
      child: widget.child,
    );
  }
}

/// Keeps the route and its application state alive when the surface rotates.
class SurfacePage extends StatefulWidget {
  const SurfacePage({
    super.key,
    required this.title,
    required this.child,
    this.detail = false,
    this.playerMenu = false,
    this.centered = false,
    this.compactPlayerMenu = false,
    this.playerMenuWidth,
    this.playerMenuHeader = true,
    this.heightRatio = .94,
    this.backgroundUrl,
    this.backgroundKind = PosterKind.artwork,
    this.blurBackground = false,
    this.prioritizeBackground = false,
    this.onBack,
  });
  final String title;
  final Widget child;
  final bool detail, playerMenu, blurBackground;
  final bool prioritizeBackground;
  final bool centered;
  final bool compactPlayerMenu;
  final double heightRatio;
  final double? playerMenuWidth;
  final bool playerMenuHeader;
  final String? backgroundUrl;
  final PosterKind backgroundKind;
  final VoidCallback? onBack;
  @override
  State<SurfacePage> createState() => _SurfacePageState();
}

class _SurfacePageState extends State<SurfacePage> {
  Offset offset = Offset.zero;
  bool expanded = false;
  Rect? trackedAnchor;
  Size? anchorScreen;
  @override
  Widget build(BuildContext context) {
    final wide = wideLayout(context);
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final route = ModalRoute.of(context);
    final anchor =
        trackedAnchor ?? (route is _SurfaceRoute ? route.anchor : null);
    if (route is _SurfaceRoute &&
        route.anchorProvider != null &&
        anchorScreen != screen) {
      anchorScreen = screen;
      // Read the underlying control after its new orientation layout completes.
      // Accessing an unrelated RenderBox's size during layout is not allowed.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final next = route.anchorProvider!();
        if (next != null && next != trackedAnchor) {
          setState(() => trackedAnchor = next);
        }
      });
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final isWindow = wide && !widget.playerMenu;
    final compactPlayerMenu =
        widget.playerMenu &&
        (widget.compactPlayerMenu || !widget.playerMenuHeader);
    final playerWindow =
        widget.playerMenu &&
        (wide ||
            anchor != null ||
            widget.playerMenuWidth != null ||
            compactPlayerMenu);
    final playbackSurface =
        widget.playerMenu || (route is _SurfaceRoute && route.playerMenu);
    final background = playbackSurface
        ? playerPanelColor(context)
        : isWindow || playerWindow
        ? (dark ? const Color(0xFF2C2C2C) : Colors.white)
        : groupedColor(context);
    final radius = BorderRadius.vertical(
      top: Radius.circular(wide || playerWindow ? 15 : 24),
      bottom: Radius.circular(wide || playerWindow ? 15 : 0),
    );
    final top = playerWindow
        ? (widget.playerMenuHeader ? 44.0 : 0.0)
        : isWindow && widget.detail
        ? 14.0
        : 60.0;
    final panel = DetailArtworkPriority(
      url: widget.prioritizeBackground && isWindow
          ? widget.backgroundUrl
          : null,
      child: ClipRRect(
        key: const Key('surface-panel'),
        clipBehavior: Clip.antiAlias,
        borderRadius: radius,
        child: AppGlassSurface(
          radius: wide || playerWindow ? 15 : 24,
          overVideo: playbackSurface,
          child: Material(
            color: liquidGlassOf(context) ? Colors.transparent : background,
            child: Stack(
              children: [
                if (isWindow && widget.backgroundUrl != null)
                  Positioned.fill(
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(
                        sigmaX: widget.blurBackground ? 40 : 0,
                        sigmaY: widget.blurBackground ? 40 : 0,
                      ),
                      child: Opacity(
                        opacity: dark ? .25 : .35,
                        child: Poster(
                          url: widget.backgroundUrl,
                          backdrop: widget.backgroundKind == PosterKind.artwork,
                          kind: widget.backgroundKind,
                          priorityImage: widget.prioritizeBackground,
                        ),
                      ),
                    ),
                  ),
                if (isWindow && widget.backgroundUrl != null)
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            background.withValues(alpha: .8),
                            background.withValues(alpha: .9),
                          ],
                        ),
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.only(
                    top: widget.detail && !wide ? 52 : top,
                    bottom: wide || playerWindow ? 0 : safe.bottom,
                  ),
                  child: GroupedBackground(
                    color: background,
                    transparentCards: playbackSurface,
                    child: widget.child,
                  ),
                ),
                if ((!widget.detail || !wide) && !playerWindow)
                  Positioned(
                    top: 16,
                    left: widget.onBack == null ? 20 : 64,
                    right: 64,
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: phoneValue(context, 16, 18),
                        fontWeight: FontWeight.w600,
                        color: labelColor(context),
                      ),
                    ),
                  ),
                if (isWindow && widget.detail)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 52,
                    height: 48,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onPanUpdate: (event) => setState(() {
                        offset = Offset(
                          (offset.dx + event.delta.dx).clamp(
                            -screen.width / 3,
                            screen.width / 3,
                          ),
                          (offset.dy + event.delta.dy).clamp(
                            -screen.height / 4,
                            screen.height / 4,
                          ),
                        );
                      }),
                      onDoubleTap: () => setState(() {
                        expanded = !expanded;
                        offset = Offset.zero;
                      }),
                    ),
                  ),
                if (widget.onBack != null && !playerWindow)
                  Positioned(
                    top: 12,
                    left: 12,
                    child: SurfaceIcon(
                      icon: CupertinoIcons.chevron_back,
                      label: '返回',
                      onPressed: widget.onBack!,
                    ),
                  ),
                if (playerWindow && widget.playerMenuHeader)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 44,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: labelColor(
                              context,
                            ).withValues(alpha: dark ? .18 : .12),
                            width: .5,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          if (widget.onBack != null) ...[
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(22, 32),
                              onPressed: widget.onBack,
                              child: Icon(
                                CupertinoIcons.chevron_back,
                                size: 18,
                                color: playbackSurface
                                    ? accentColor(context)
                                    : labelColor(context),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(
                            child: Text(
                              widget.title,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Tooltip(
                            message: '关闭',
                            child: CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(24, 32),
                              onPressed: () => Navigator.of(context).pop(),
                              child: Icon(
                                CupertinoIcons.xmark,
                                size: 18,
                                color: playbackSurface
                                    ? accentColor(context)
                                    : labelColor(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!playerWindow)
                  Positioned(
                    top: isWindow ? 8 : 12,
                    right: isWindow ? 8 : 12,
                    child: SurfaceIcon(
                      icon: CupertinoIcons.xmark,
                      label: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    final width = playerWindow
        ? (widget.playerMenuWidth ?? (widget.compactPlayerMenu ? 288.0 : 300.0))
              .clamp(
                0.0,
                (screen.width - safe.horizontal - 40).clamp(
                  0.0,
                  double.infinity,
                ),
              )
        : wide
        ? (widget.playerMenu
              ? (widget.compactPlayerMenu ? 288.0 : 300.0)
              : expanded
              ? screen.width - 24
              : (screen.width - 40).clamp(0.0, 810.0))
        : screen.width;
    final height = wide || playerWindow
        ? (widget.playerMenu
              ? (widget.compactPlayerMenu
                    ? (screen.height - safe.vertical - 126).clamp(150.0, 420.0)
                    : (screen.height - safe.vertical - 110).clamp(180.0, 600.0))
              : expanded
              ? screen.height - safe.vertical - 24
              : screen.height * .8 - 40)
        : widget.playerMenu && widget.compactPlayerMenu
        ? ((screen.height - safe.top) * .72).clamp(0.0, 420.0)
        : (screen.height - safe.top) * widget.heightRatio;
    if (anchor != null && widget.playerMenu) {
      return CustomSingleChildLayout(
        delegate: MenuPlacement(
          anchor: anchor,
          width: width,
          maxHeight: height,
          alignRight: anchor.center.dx >= screen.width / 2,
          centerOnAnchor: true,
          forceAbove: true,
          gap: 4,
          safe: EdgeInsets.fromLTRB(
            safe.left,
            safe.top,
            safe.right,
            MediaQuery.viewInsetsOf(context).bottom > safe.bottom
                ? MediaQuery.viewInsetsOf(context).bottom
                : safe.bottom,
          ),
        ),
        child: SizedBox(
          height: compactPlayerMenu ? null : height,
          child: panel,
        ),
      );
    }
    return Align(
      alignment: widget.centered
          ? Alignment.center
          : wide || playerWindow
          ? (widget.playerMenu ? Alignment.bottomRight : Alignment.center)
          : Alignment.bottomCenter,
      child: Padding(
        padding: playerWindow && !widget.centered
            ? EdgeInsets.only(right: 20 + safe.right, bottom: 82 + safe.bottom)
            : EdgeInsets.zero,
        child: Transform.translate(
          offset: isWindow ? offset : Offset.zero,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: SizedBox(
              width: width,
              height: compactPlayerMenu ? null : height,
              child: panel,
            ),
          ),
        ),
      ),
    );
  }
}

class SurfaceIcon extends StatelessWidget {
  const SurfaceIcon({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final route = ModalRoute.of(context);
    if (liquidGlassOf(context)) {
      final size = phoneValue(context, 36, 40);
      return Tooltip(
        message: label,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: onPressed,
          child: AppGlassSurface(
            radius: size / 2,
            role: GlassRole.control,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(
                icon,
                size: 16,
                color: route is _SurfaceRoute && route.playerMenu
                    ? accentColor(context)
                    : labelColor(context),
              ),
            ),
          ),
        ),
      );
    }
    if (route is _SurfaceRoute && route.playerMenu) {
      return Tooltip(
        message: label,
        child: CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: onPressed,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: Color(0xFF34343A),
              shape: BoxShape.circle,
            ),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(icon, size: 16, color: accentColor(context)),
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: label,
      // A flat circle avoids shader lighting/shadows leaking into the corner.
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minimumSize: const Size(44, 44),
        onPressed: onPressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF34343A)
                : const Color(0xFFF0F0F5),
            shape: BoxShape.circle,
          ),
          child: SizedBox(
            width: phoneValue(context, 32, 40),
            height: phoneValue(context, 32, 40),
            child: Icon(icon, size: 16, color: labelColor(context)),
          ),
        ),
      ),
    );
  }
}

/// A short choice list should occupy only its contents, even on a tablet.
class SelectionMenu extends StatelessWidget {
  const SelectionMenu({super.key, required this.label, required this.children});
  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: wideLayout(context)
              ? Alignment.center
              : Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth,
              maxHeight: constraints.maxHeight.clamp(0.0, 420.0),
            ),
            child: IntrinsicWidth(
              child: Semantics(
                label: label,
                child: AppGlassSurface(
                  radius: 16,
                  child: Material(
                    key: const Key('selection-menu-panel'),
                    color: liquidGlassOf(context)
                        ? Colors.transparent
                        : Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    clipBehavior: Clip.antiAlias,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: children,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class SelectionRow extends StatelessWidget {
  const SelectionRow(
    this.title, {
    super.key,
    this.subtitle,
    this.selected = false,
    this.icon,
    required this.onTap,
  });
  final String title;
  final String? subtitle;
  final bool selected;
  final IconData? icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: SettingsRow(
      title,
      subtitle: subtitle,
      icon: icon,
      onTap: onTap,
      selected: selected,
      showDisclosure: false,
      singleLine: true,
    ),
  );
}
