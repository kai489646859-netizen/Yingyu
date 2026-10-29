import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'poster_service.dart';
import 'style.dart';

class ScrollToTop extends StatefulWidget {
  const ScrollToTop({
    super.key,
    required this.controller,
    required this.child,
    this.bottom = 20,
    this.right = 18,
    this.referenceStyle = false,
    this.posterAware = true,
  });
  final ScrollController controller;
  final Widget child;
  final double bottom, right;
  final bool referenceStyle, posterAware;
  @override
  State<ScrollToTop> createState() => _ScrollToTopState();
}

class _ScrollToTopState extends State<ScrollToTop> {
  bool returning = false;
  bool pageEnabled = true;
  Timer? resumeImages;
  final showTop = ValueNotifier(false);

  void updateVisibility() {
    final controller = widget.controller;
    showTop.value =
        controller.hasClients &&
        controller.position.hasViewportDimension &&
        controller.offset >
            controller.position.viewportDimension.clamp(480, 1000);
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(updateVisibility);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) updateVisibility();
    });
  }

  @override
  void didUpdateWidget(ScrollToTop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(updateVisibility);
      widget.controller.addListener(updateVisibility);
      updateVisibility();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    pageEnabled = TickerMode.valuesOf(context).enabled;
    if (!pageEnabled) {
      // A retained tab stops ticking when hidden. Cancel its return animation
      // so it cannot hold the global image pause until that tab is revisited.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || pageEnabled) return;
        if (returning && widget.controller.hasClients) {
          widget.controller.jumpTo(widget.controller.offset);
        }
        resumeImages?.cancel();
        if (widget.posterAware) PosterDemand.pause(this, false);
        if (returning) setState(() => returning = false);
      });
    }
  }

  Future<void> go() async {
    if (returning || !widget.controller.hasClients) return;
    setState(() => returning = true);
    resumeImages?.cancel();
    if (widget.posterAware) PosterDemand.pause(this, true);
    try {
      await widget.controller.animateTo(
        0,
        duration: Duration(
          milliseconds: (550 + widget.controller.offset / 12).round().clamp(
            550,
            1200,
          ),
        ),
        curve: Curves.easeInOutCubic,
      );
    } finally {
      if (widget.posterAware && mounted && pageEnabled) {
        // Match alphabet scrubbing: allow the final visibility callbacks to
        // retire offscreen cards before restoring visible image demand.
        resumeImages = Timer(const Duration(milliseconds: 120), () {
          PosterDemand.pause(this, false);
        });
      }
      if (mounted) setState(() => returning = false);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(updateVisibility);
    showTop.dispose();
    resumeImages?.cancel();
    if (widget.posterAware) PosterDemand.pause(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(child: widget.child),
      ValueListenableBuilder<bool>(
        valueListenable: showTop,
        builder: (context, show, _) {
          if (!returning && !show) return const SizedBox.shrink();
          return Positioned(
            right: widget.right,
            bottom: widget.bottom,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(23),
                border: widget.referenceStyle
                    ? Border.all(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF354157)
                            : const Color(0xFFCAD0DA),
                      )
                    : null,
              ),
              position: DecorationPosition.foreground,
              child: CupertinoButton(
                key: const Key('scroll-to-top'),
                padding: EdgeInsets.symmetric(
                  horizontal: widget.referenceStyle ? 18 : 14,
                  vertical: 11,
                ),
                borderRadius: BorderRadius.circular(22),
                color: widget.referenceStyle
                    ? Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFF172134)
                          : const Color(0xFFF1F3F7)
                    : Theme.of(context).colorScheme.surfaceContainerHigh,
                onPressed: returning ? null : go,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!widget.referenceStyle)
                      Icon(
                        CupertinoIcons.arrow_up_to_line,
                        size: 17,
                        color: accentColor(context),
                      ),
                    if (!widget.referenceStyle) const SizedBox(width: 6),
                    Text(
                      '回到顶部',
                      style: TextStyle(
                        fontSize: widget.referenceStyle ? 16 : 13,
                        fontWeight: widget.referenceStyle
                            ? FontWeight.w600
                            : null,
                        color: labelColor(context),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ],
  );
}
