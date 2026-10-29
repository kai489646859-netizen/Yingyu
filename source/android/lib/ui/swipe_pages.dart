import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// One retained page per tab, with a continuous horizontal drag and snap.
/// Commit the destination on release; settling must not block its scrollables.
class SwipePages extends StatefulWidget {
  const SwipePages({
    super.key,
    required this.index,
    required this.onChanged,
    required this.children,
    this.onProgress,
    this.reducedMotion = false,
    this.enabled = true,
  });
  final int index;
  final ValueChanged<int> onChanged;
  final ValueChanged<double>? onProgress;
  final List<Widget> children;
  final bool reducedMotion, enabled;
  @override
  State<SwipePages> createState() => _SwipePagesState();
}

class _SwipePagesState extends State<SwipePages>
    with SingleTickerProviderStateMixin {
  late final controller = PageController(
    initialPage: widget.index,
    keepPage: false,
  );
  int revision = 0;
  int? target;
  bool dragging = false;
  double startPage = 0, fromPage = 0, toPage = 0;
  int startIndex = 0;
  double dragPage = 0, dragTravel = 0, fromEdge = 0;
  final edge = ValueNotifier<double>(0);
  late final AnimationController motion;
  _PageMotionActivity? activity;

  @override
  void initState() {
    super.initState();
    motion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(animate);
    motion.addStatusListener((status) {
      if (status == AnimationStatus.completed && !dragging) activity?.stop();
    });
    controller.addListener(reportProgress);
  }

  void reportProgress() {
    if (controller.hasClients && controller.position.hasContentDimensions) {
      widget.onProgress?.call(controller.page ?? widget.index.toDouble());
    }
  }

  void moveTo(double page) {
    if (!controller.hasClients) return;
    final position = controller.position;
    final pixels =
        page.clamp(0, widget.children.length - 1) * position.viewportDimension;
    if ((position.pixels - pixels).abs() < .001) return;
    if (activity == null || activity!.finished) {
      activity = _PageMotionActivity(position as ScrollActivityDelegate);
      position.beginActivity(activity!);
    }
    activity!.move(pixels);
  }

  void animate() {
    final progress = Curves.easeOutCubic.transform(motion.value);
    moveTo(fromPage + (toPage - fromPage) * progress);
    edge.value = fromEdge * (1 - progress);
  }

  void settle(int next) {
    target = next;
    motion.stop();
    if (!controller.hasClients) return;
    fromPage = controller.page ?? widget.index.toDouble();
    fromEdge = edge.value;
    toPage = next.toDouble();
    if (widget.reducedMotion || MediaQuery.disableAnimationsOf(context)) {
      moveTo(toPage);
      edge.value = 0;
      activity?.stop();
    } else {
      motion.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(SwipePages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      dragging = false;
      settle(widget.index);
    }
    if (oldWidget.index != widget.index && target != widget.index) {
      final token = ++revision;
      motion.stop();
      FocusManager.instance.primaryFocus?.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || token != revision || !controller.hasClients) return;
        settle(widget.index);
      });
    }
  }

  void start(DragStartDetails details) {
    dragging = true;
    revision++;
    motion.stop();
    target = null;
    startPage = controller.page ?? widget.index.toDouble();
    startIndex = widget.index;
    dragTravel = 0;
    final width = controller.position.viewportDimension;
    final residual = edge.value == 0
        ? 0.0
        : edge.value.sign *
              -180 *
              math.log(1 - (edge.value.abs() / 52).clamp(0, .999));
    dragPage = startPage - residual / width;
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void update(DragUpdateDetails details) {
    final width = controller.position.viewportDimension;
    if (width <= 0) return;
    dragTravel -= details.delta.dx / width;
    dragPage -= details.delta.dx / width;
    final bounded = dragPage.clamp(0, widget.children.length - 1).toDouble();
    final excess = (bounded - dragPage) * width;
    edge.value = excess.sign * 52 * (1 - math.exp(-excess.abs() / 180));
    moveTo(bounded);
  }

  void end(DragEndDetails details) {
    dragging = false;
    final distance = dragTravel;
    final velocity = details.primaryVelocity ?? 0;
    // A second drag can interrupt the preceding snap. The committed tab, not
    // a partly animated pixel position, is the origin of that new gesture.
    final origin = startIndex;
    var next = origin;
    if (distance.abs() >= .18 ||
        (velocity.abs() > 550 && distance.abs() > .04)) {
      final forward = velocity.abs() > 550 ? velocity < 0 : distance > 0;
      next = origin + (forward ? 1 : -1);
    }
    next = next.clamp(0, widget.children.length - 1);
    settle(next);
    if (next != widget.index) widget.onChanged(next);
  }

  @override
  void dispose() {
    revision++;
    motion.dispose();
    controller.dispose();
    edge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      if (widget.enabled)
        _PageDrag: GestureRecognizerFactoryWithHandlers<_PageDrag>(
          () => _PageDrag(),
          (recognizer) => recognizer
            ..onStart = start
            ..onUpdate = update
            ..onEnd = end
            ..onCancel = () {
              if (!dragging) return;
              dragging = false;
              settle(widget.index);
            },
        ),
    },
    child: ClipRect(
      child: ValueListenableBuilder<double>(
        valueListenable: edge,
        builder: (context, offset, child) => Transform.translate(
          key: const Key('page-edge-feedback'),
          offset: Offset(offset, 0),
          child: child,
        ),
        child: PageView(
          key: const Key('main-swipe-pages'),
          controller: controller,
          // One activity spans the drag and snap. Child vertical scrollables
          // remain interactive throughout the short horizontal settling.
          pageSnapping: false,
          physics: const NeverScrollableScrollPhysics(),
          // Lay out the adjacent cached page before the first gesture needs it.
          // Inactive LibraryPage does not initiate its network initialization.
          allowImplicitScrolling: true,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              _KeptPage(
                key: ValueKey(i),
                child: ExcludeSemantics(
                  excluding: i != widget.index,
                  child: TickerMode(
                    enabled: i == widget.index,
                    child: widget.children[i],
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _PageMotionActivity extends ScrollActivity {
  _PageMotionActivity(super.delegate);
  bool finished = false;
  void move(double pixels) {
    if (!finished) delegate.setPixels(pixels);
  }

  void stop() {
    if (!finished) delegate.goIdle();
  }

  @override
  void applyNewDimensions() {}
  @override
  bool get shouldIgnorePointer => false;
  @override
  bool get isScrolling => true;
  @override
  double get velocity => 0;
  @override
  void dispose() {
    finished = true;
    super.dispose();
  }
}

/// A vertical or diagonal start belongs to content for the entire gesture.
/// Carousels retain their normal, earlier horizontal gesture threshold.
class _PageDrag extends HorizontalDragGestureRecognizer {
  _PageDrag() {
    onlyAcceptDragOnThreshold = true;
    dragStartBehavior = DragStartBehavior.down;
  }
  int? pointer;
  Offset origin = Offset.zero, travel = Offset.zero;
  bool horizontal = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (pointer == null) {
      pointer = event.pointer;
      origin = event.position;
      travel = Offset.zero;
      horizontal = false;
    }
    super.addAllowedPointer(event);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer == pointer && event is PointerMoveEvent && !horizontal) {
      travel = event.position - origin;
      if (travel.dy.abs() > 12 && travel.dy.abs() >= travel.dx.abs() * .75) {
        resolve(GestureDisposition.rejected);
        return;
      }
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    horizontal =
        travel.dx.abs() > math.max(24, deviceTouchSlop ?? 18) &&
        travel.dx.abs() > travel.dy.abs() * 2.2;
    return horizontal;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    super.didStopTrackingLastPointer(pointer);
    this.pointer = null;
  }
}

class _KeptPage extends StatefulWidget {
  const _KeptPage({super.key, required this.child});
  final Widget child;
  @override
  State<_KeptPage> createState() => _KeptPageState();
}

class _KeptPageState extends State<_KeptPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// A carousel or letter rail owns gestures within its rectangle even when a
/// short row cannot scroll. Its inner scrollable gets first choice in the arena.
class HorizontalPageSwipeBoundary extends StatelessWidget {
  const HorizontalPageSwipeBoundary({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onHorizontalDragUpdate: (_) {},
    child: child,
  );
}
