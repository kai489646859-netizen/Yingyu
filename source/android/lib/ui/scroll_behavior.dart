import 'package:flutter/material.dart';

/// Decorate each real scroll viewport with its own controller. This also covers
/// popup lists and nested overviews without sharing a PrimaryScrollController.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (details.controller == null ||
        axisDirectionToAxis(details.direction) == Axis.horizontal) {
      return child;
    }
    return _ViewportScrollbar(child: child);
  }
}

class _ViewportScrollbar extends StatefulWidget {
  const _ViewportScrollbar({required this.child});
  final Widget child;
  @override
  State<_ViewportScrollbar> createState() => _ViewportScrollbarState();
}

class _ViewportScrollbarState extends State<_ViewportScrollbar> {
  final controller = ScrollController(keepScrollOffset: false);
  ScrollPosition? position;

  @override
  void dispose() {
    if (position != null) controller.detach(position!);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Retained tabs and AnimatedSwitcher children can share the inherited
    // PrimaryScrollController. Observe only this Scrollable's position, without
    // replacing its controller, physics, saved offset or keyboard behavior.
    final current = context
        .findAncestorStateOfType<ScrollableState>()
        ?.position;
    if (current != position) {
      if (position != null) controller.detach(position!);
      position = current;
      if (current != null) controller.attach(current);
    }
    if (current == null) return widget.child;
    return RawScrollbar(
      controller: controller,
      thumbVisibility: true,
      interactive: true,
      thickness: 3,
      radius: Radius.zero,
      minThumbLength: 28,
      crossAxisMargin: 0,
      mainAxisMargin: 0,
      padding: EdgeInsets.zero,
      thumbColor: const Color(0xFFB0B0B0).withValues(alpha: .9),
      child: widget.child,
    );
  }
}
