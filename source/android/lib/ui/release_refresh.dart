import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

/// A pull only commits at pointer release. Returning inside the threshold or
/// losing the gesture cancels it; scroll bounce and nested carousels cannot arm.
class ReleaseRefresh extends StatefulWidget {
  const ReleaseRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.busy = false,
    this.triggerDistance = 44,
  });
  final Future<void> Function() onRefresh;
  final Widget child;
  final bool busy;
  final double triggerDistance;

  @override
  State<ReleaseRefresh> createState() => _ReleaseRefreshState();
}

class _ReleaseRefreshState extends State<ReleaseRefresh> {
  final pointers = <int>{};
  double pull = 0;
  double travel = 0;
  bool dragging = false, refreshing = false;
  bool get busy => refreshing || widget.busy;
  double get distance => math.min(pull, math.max(0, travel));

  void cancel() {
    if (!dragging && pull == 0) return;
    setState(() {
      dragging = false;
      pull = 0;
    });
  }

  void release(PointerEvent event, {bool canceled = false}) {
    pointers.remove(event.pointer);
    final commit =
        !canceled &&
        pointers.isEmpty &&
        dragging &&
        !busy &&
        distance >= widget.triggerDistance;
    cancel();
    if (commit) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (busy) return;
    setState(() => refreshing = true);
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) setState(() => refreshing = false);
    }
  }

  bool observe(ScrollNotification event) {
    if (event.depth != 0 || event.metrics.axisDirection != AxisDirection.down) {
      return false;
    }
    if (event is ScrollUpdateNotification &&
        event.dragDetails != null &&
        pointers.length == 1 &&
        !busy) {
      setState(() {
        dragging = true;
        pull = math.max(
          0,
          event.metrics.minScrollExtent - event.metrics.pixels,
        );
      });
    }
    if (event is ScrollEndNotification && pointers.isEmpty) cancel();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final text = distance >= widget.triggerDistance ? '松手刷新' : '下拉刷新';
    final accent = CupertinoTheme.of(context).primaryColor;
    final foreground = accent.computeLuminance() > .179
        ? CupertinoColors.black
        : CupertinoColors.white;
    return Listener(
      onPointerDown: (event) {
        if (pointers.isEmpty) travel = 0;
        pointers.add(event.pointer);
        if (pointers.length > 1) cancel();
      },
      onPointerMove: (event) {
        if (pointers.length == 1) {
          setState(() => travel += event.delta.dy);
        }
      },
      onPointerUp: release,
      onPointerCancel: (event) => release(event, canceled: true),
      child: NotificationListener<ScrollNotification>(
        onNotification: observe,
        child: Stack(
          children: [
            // Manual refresh keeps the same gap until its actual future ends.
            // Background refresh continues to use the page heading indicator.
            if (refreshing)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: 48,
                child: Center(
                  child: Semantics(
                    label: '正在刷新',
                    liveRegion: true,
                    child: CupertinoActivityIndicator(
                      key: Key('pull-refresh-loading'),
                    ),
                  ),
                ),
              ),
            if (!busy && dragging && distance > 0)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: math.min(pull, 56),
                child: IgnorePointer(
                  child: ClipRect(
                    child: Semantics(
                      liveRegion: true,
                      child: Center(
                        child: Container(
                          key: const Key('pull-refresh-prompt'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: accent,
                            border: Border.all(
                              color: accent.withValues(alpha: .45),
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                distance >= widget.triggerDistance
                                    ? CupertinoIcons.arrow_up
                                    : CupertinoIcons.arrow_down,
                                size: 18,
                                color: foreground,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                text,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: foreground,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.only(top: refreshing ? 48 : 0),
              child: widget.child,
            ),
          ],
        ),
      ),
    );
  }
}

class ReleaseRefreshScrollView extends StatelessWidget {
  const ReleaseRefreshScrollView({
    super.key,
    required this.onRefresh,
    required this.slivers,
    this.controller,
    this.scrollCacheExtent,
    this.physics,
    this.busy = false,
  });
  final Future<void> Function() onRefresh;
  final List<Widget> slivers;
  final ScrollController? controller;
  final ScrollCacheExtent? scrollCacheExtent;
  final ScrollPhysics? physics;
  final bool busy;

  @override
  Widget build(BuildContext context) => ReleaseRefresh(
    onRefresh: onRefresh,
    busy: busy,
    child: CustomScrollView(
      controller: controller,
      scrollCacheExtent: scrollCacheExtent,
      physics:
          physics ??
          const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      slivers: slivers,
    ),
  );
}
