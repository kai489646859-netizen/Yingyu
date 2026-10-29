import 'dart:ui' show SemanticsRole;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'expansion_chevron.dart';
import 'visual_effects.dart';
import 'menu_placement.dart';

double compactMenuWidth(
  BuildContext context,
  Iterable<String> labels, {
  double extra = 24,
  double minimum = 48,
  double maximum = double.infinity,
  double fontSize = 14,
  FontWeight weight = FontWeight.w400,
}) {
  var width = 0.0;
  for (final label in labels) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    if (painter.width > width) width = painter.width;
    painter.dispose();
  }
  final available =
      MediaQuery.sizeOf(context).width -
      MediaQuery.paddingOf(context).horizontal -
      16;
  return (width.ceilToDouble() + extra + 2)
      .clamp(minimum, maximum)
      .clamp(0.0, available.clamp(0.0, double.infinity));
}

/// Only the small trigger is interactive. Menus grow left from its right edge.
class AnchoredMenuController {
  VoidCallback? _open;
  void open() => _open?.call();
}

class AnchoredMenuButton<T> extends StatefulWidget {
  const AnchoredMenuButton({
    super.key,
    required this.id,
    required this.label,
    required this.items,
    required this.onSelected,
    this.enabled = true,
    this.icon = CupertinoIcons.chevron_forward,
    this.expandedIcon,
    this.color,
    this.background,
    this.iconSize = 15,
    required this.menuWidth,
    this.reducedMotion = false,
    this.controller,
    this.hitSize = 44,
    this.interactive = true,
    this.child,
    this.maxHeight = double.infinity,
    this.initialValue,
    this.onOpenChanged,
    this.onDirectionChanged,
  });
  final String id, label;
  final List<PopupMenuEntry<T>> Function(BuildContext) items;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final bool interactive;
  final IconData icon;
  final IconData? expandedIcon;
  final double iconSize;
  final double menuWidth;
  final double hitSize;
  final bool reducedMotion;
  final AnchoredMenuController? controller;
  final Color? color, background;
  final Widget? child;
  final double maxHeight;
  final T? initialValue;
  final ValueChanged<bool>? onOpenChanged;
  final ValueChanged<bool>? onDirectionChanged;
  @override
  State<AnchoredMenuButton<T>> createState() => _AnchoredMenuButtonState<T>();
}

class _AnchoredMenuButtonState<T> extends State<AnchoredMenuButton<T>>
    with WidgetsBindingObserver {
  final anchorKey = GlobalKey();
  ScrollPosition? scroll;
  PopupRoute<T>? menu;
  bool opening = false;
  bool opensUp = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?._open = open;
  }

  void dismiss() {
    final route = menu;
    menu = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (scroll != next) {
      scroll?.removeListener(dismiss);
      scroll = next;
      scroll?.addListener(dismiss);
    }
    if (!TickerMode.valuesOf(context).enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
    }
  }

  @override
  void didChangeMetrics() => dismiss();
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) dismiss();
  }

  @override
  void didUpdateWidget(covariant AnchoredMenuButton<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._open = null;
      widget.controller?._open = open;
    }
    if (!widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
    }
  }

  Future<void> open() async {
    if (opening || !widget.enabled) return;
    final box = anchorKey.currentContext!.findRenderObject() as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    setState(() => opening = true);
    widget.onOpenChanged?.call(true);
    try {
      final entries = widget.items(context);
      final route = _AnchoredMenuRoute<T>(
        anchor: anchor,
        width: widget.menuWidth,
        maxHeight: widget.maxHeight,
        surfaceColor: Theme.of(context).colorScheme.surface,
        label: widget.label,
        dismissLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        themes: InheritedTheme.capture(
          from: context,
          to: Navigator.of(context).context,
        ),
        entries: entries,
        initialValue: widget.initialValue,
        onDirection: (up) {
          if (!mounted || !opening || menu?.isActive != true) return;
          if (opensUp != up) setState(() => opensUp = up);
          widget.onDirectionChanged?.call(up);
        },
      );
      menu = route;
      final selected = await Navigator.of(context).push(route);
      if (mounted && widget.enabled && selected != null) {
        widget.onSelected(selected);
      }
    } finally {
      menu = null;
      if (mounted) setState(() => opening = false);
      if (mounted) widget.onOpenChanged?.call(false);
    }
  }

  @override
  void dispose() {
    widget.controller?._open = null;
    scroll?.removeListener(dismiss);
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => dismiss());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.label,
    child: Semantics(
      label: widget.label,
      button: widget.interactive,
      expanded: widget.expandedIcon == null ? null : opening,
      child: SizedBox(
        key: anchorKey,
        width: widget.child == null ? widget.hitSize : null,
        height: widget.child == null ? widget.hitSize : null,
        child: widget.interactive
            ? CupertinoButton(
                key: ValueKey(widget.id),
                padding: EdgeInsets.zero,
                minimumSize: Size.square(widget.hitSize),
                onPressed: widget.enabled ? open : null,
                child:
                    widget.child ??
                    Container(
                      width: widget.expandedIcon == null ? 26 : 32,
                      height: widget.expandedIcon == null ? 26 : 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color:
                            widget.background ??
                            (widget.expandedIcon == null
                                ? null
                                : Theme.of(context).colorScheme.primary
                                      .withValues(alpha: opening ? .16 : .08)),
                        shape: BoxShape.circle,
                      ),
                      child: widget.expandedIcon != null
                          ? ExpansionChevron(
                              expanded: opening,
                              opensUp: opensUp,
                              size: widget.iconSize,
                              color:
                                  widget.color ??
                                  Theme.of(context).colorScheme.primary,
                              reducedMotion: widget.reducedMotion,
                            )
                          : Icon(
                              widget.icon,
                              size: widget.iconSize,
                              color:
                                  widget.color ??
                                  Theme.of(context).colorScheme.primary,
                            ),
                    ),
              )
            : SizedBox(
                key: ValueKey(widget.id),
                child: Center(
                  child: ExpansionChevron(
                    expanded: opening,
                    opensUp: opensUp,
                    size: widget.iconSize,
                    color:
                        widget.color ?? Theme.of(context).colorScheme.primary,
                    reducedMotion: widget.reducedMotion,
                  ),
                ),
              ),
      ),
    ),
  );
}

class _AnchoredMenuRoute<T> extends PopupRoute<T> {
  _AnchoredMenuRoute({
    required this.anchor,
    required this.width,
    required this.maxHeight,
    required this.surfaceColor,
    required this.label,
    required this.dismissLabel,
    required this.themes,
    required this.entries,
    this.initialValue,
    required this.onDirection,
  });
  final Rect anchor;
  final double width, maxHeight;
  final Color surfaceColor;
  final String label, dismissLabel;
  final CapturedThemes themes;
  final List<PopupMenuEntry<T>> entries;
  final T? initialValue;
  final ValueChanged<bool> onDirection;
  final selectedKey = GlobalKey();
  bool revealed = false;
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String get barrierLabel => dismissLabel;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 150);
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    if (!revealed && initialValue != null) {
      revealed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final selected = selectedKey.currentContext;
        if (isActive && selected != null) Scrollable.ensureVisible(selected);
      });
    }
    final query = MediaQuery.of(context);
    return themes.wrap(
      Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              navigator?.pop();
              return null;
            },
          ),
        },
        child: CustomSingleChildLayout(
          delegate: MenuPlacement(
            anchor: anchor,
            width: width,
            maxHeight: maxHeight,
            onDirection: onDirection,
            safe: EdgeInsets.fromLTRB(
              query.padding.left,
              query.padding.top,
              query.padding.right,
              query.viewInsets.bottom > query.padding.bottom
                  ? query.viewInsets.bottom
                  : query.padding.bottom,
            ),
          ),
          child: Semantics(
            role: SemanticsRole.menu,
            scopesRoute: true,
            namesRoute: true,
            label: label,
            explicitChildNodes: true,
            child: AppGlassSurface(
              radius: 12,
              child: Material(
                key: const Key('anchored-menu-panel'),
                elevation: liquidGlassOf(context) ? 0 : 8,
                color: liquidGlassOf(context)
                    ? Colors.transparent
                    : surfaceColor,
                surfaceTintColor: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: ListBody(
                    children: [
                      for (final entry in entries)
                        if (initialValue != null &&
                            entry.represents(initialValue))
                          KeyedSubtree(key: selectedKey, child: entry)
                        else
                          entry,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child);
}
