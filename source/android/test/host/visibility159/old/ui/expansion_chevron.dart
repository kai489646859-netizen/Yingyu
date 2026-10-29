import 'package:flutter/cupertino.dart';

/// One glyph rotates, so interrupted open/close transitions remain continuous.
class ExpansionChevron extends StatelessWidget {
  const ExpansionChevron({
    super.key,
    required this.expanded,
    this.opensUp = false,
    this.size = 18,
    this.color,
    this.reducedMotion = false,
  });
  final bool expanded, reducedMotion, opensUp;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: expanded ? (opensUp ? -.25 : .25) : 0,
    duration: reducedMotion || MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    curve: Curves.easeInOutCubic,
    child: Icon(CupertinoIcons.chevron_forward, size: size, color: color),
  );
}
