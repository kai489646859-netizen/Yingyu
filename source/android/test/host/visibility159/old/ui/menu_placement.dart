import 'dart:math' as math;
import 'package:flutter/widgets.dart';

/// Decide after layout, using the panel's actual height (including text scale).
/// If neither side fits, use the larger side and let the panel scroll.
class MenuPlacement extends SingleChildLayoutDelegate {
  MenuPlacement({
    required this.anchor,
    this.safe = EdgeInsets.zero,
    this.width,
    this.maxHeight = double.infinity,
    this.alignRight = true,
    this.centerOnAnchor = false,
    this.forceAbove = false,
    this.gap = 0,
    this.onDirection,
  });
  final Rect anchor;
  final EdgeInsets safe;
  final double? width;
  final double maxHeight, gap;
  final bool alignRight;
  final bool centerOnAnchor, forceAbove;
  final ValueChanged<bool>? onDirection;

  double above(Size size) => math.max(0, anchor.top - safe.top - 8 - gap);
  double below(Size size) =>
      math.max(0, size.height - safe.bottom - 8 - anchor.bottom - gap);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final availableWidth = math.max(0.0, size.width - safe.horizontal - 16);
    final actualWidth = width?.clamp(0.0, availableWidth);
    return BoxConstraints(
      minWidth: actualWidth ?? math.min(48, availableWidth),
      maxWidth: actualWidth ?? availableWidth,
      maxHeight: math.min(
        maxHeight,
        forceAbove ? above(size) : math.max(above(size), below(size)),
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final down =
        !forceAbove &&
        (childSize.height <= below(size) + .01 ||
            (childSize.height > above(size) + .01 &&
                below(size) >= above(size)));
    // Reporting after layout avoids changing the trigger while it is building.
    if (onDirection != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onDirection!(!down));
    }
    return Offset(
      (centerOnAnchor
              ? anchor.center.dx - childSize.width / 2
              : alignRight
              ? anchor.right - childSize.width
              : anchor.left)
          .clamp(
            safe.left + 8,
            math.max(
              safe.left + 8,
              size.width - safe.right - childSize.width - 8,
            ),
          ),
      (down ? anchor.bottom + gap : anchor.top - childSize.height - gap).clamp(
        safe.top + 8,
        math.max(
          safe.top + 8,
          size.height - safe.bottom - childSize.height - 8,
        ),
      ),
    );
  }

  @override
  bool shouldRelayout(MenuPlacement oldDelegate) =>
      anchor != oldDelegate.anchor ||
      safe != oldDelegate.safe ||
      width != oldDelegate.width ||
      maxHeight != oldDelegate.maxHeight ||
      alignRight != oldDelegate.alignRight ||
      centerOnAnchor != oldDelegate.centerOnAnchor ||
      forceAbove != oldDelegate.forceAbove ||
      gap != oldDelegate.gap;
}
