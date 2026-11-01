import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Preview a continuous thumb position; commit the page only on release.
/// Pointer moves update only a transform, retaining the buttons and backdrop.
class NavigationScrub extends StatefulWidget {
  const NavigationScrub({
    super.key,
    required this.index,
    required this.onChanged,
    required this.itemWidth,
    required this.indicator,
    required this.child,
    required this.reducedMotion,
    this.progress,
  });
  final int index;
  final ValueChanged<int> onChanged;
  final double itemWidth;
  final Widget indicator, child;
  final bool reducedMotion;
  final ValueListenable<double>? progress;
  @override
  State<NavigationScrub> createState() => _NavigationScrubState();
}

class _NavigationScrubState extends State<NavigationScrub>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final position = ValueNotifier<double>(0);
  late final AnimationController settle;
  bool held = false, overridden = false, approaching = false;
  int? pointer;
  int? pending;
  int revision = 0;
  double from = 0, to = 0, segment = 0;
  Size? screen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.progress?.addListener(externalProgress);
    settle =
        AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 180),
          )
          ..addListener(() {
            final phase = Curves.easeOutCubic.transform(settle.value);
            final fraction = segment >= 1
                ? 1.0
                : ((phase - segment) / (1 - segment)).clamp(0.0, 1.0);
            position.value = from + (to - from) * fraction;
          })
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed) {
              approaching = false;
              releaseOverride();
            }
          });
  }

  double get external => (widget.progress?.value ?? widget.index.toDouble())
      .clamp(0, 3)
      .toDouble();

  void externalProgress() => releaseOverride();
  void releaseOverride() {
    if (!mounted ||
        held ||
        !overridden ||
        settle.isAnimating ||
        pending != widget.index) {
      return;
    }
    if ((external - widget.index).abs() > .001) return;
    setState(() {
      overridden = false;
      pending = null;
    });
  }

  void snap(int index) {
    approaching = false;
    segment = 0;
    settle.duration = const Duration(milliseconds: 180);
    from = position.value;
    to = index.toDouble();
    pending = index;
    if (widget.reducedMotion ||
        MediaQuery.disableAnimationsOf(context) ||
        (from - to).abs() < .001) {
      settle.stop();
      position.value = to;
      releaseOverride();
    } else {
      settle.forward(from: 0);
    }
  }

  void reset() {
    revision++;
    pointer = null;
    settle.stop();
    held = false;
    approaching = false;
    overridden = false;
    pending = null;
  }

  @override
  void didUpdateWidget(NavigationScrub oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.progress != widget.progress) {
      oldWidget.progress?.removeListener(externalProgress);
      widget.progress?.addListener(externalProgress);
    }
    if (oldWidget.progress != widget.progress ||
        oldWidget.itemWidth != widget.itemWidth ||
        (oldWidget.index != widget.index && pending != widget.index)) {
      reset();
    }
    // The parent may commit synchronously before page pixels reach the target.
    // Retain the released thumb until both animations agree, without a jump.
    if (overridden &&
        !held &&
        !settle.isAnimating &&
        pending == widget.index &&
        (external - widget.index).abs() <= .001) {
      overridden = false;
      pending = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = MediaQuery.sizeOf(context);
    if ((screen != null && screen != next) ||
        MediaQuery.viewInsetsOf(context).bottom > 0 ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      reset();
    }
    screen = next;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && (held || overridden)) {
      setState(reset);
    }
  }

  double pageAt(Offset local) =>
      (local.dx / widget.itemWidth - .5).clamp(0, 3).toDouble();
  void start(PointerDownEvent details) {
    if (pointer != null ||
        details.buttons != kPrimaryButton ||
        widget.itemWidth <= 0) {
      return;
    }
    pointer = details.pointer;
    revision++;
    settle.stop();
    from = overridden ? position.value : external;
    to = pageAt(details.localPosition);
    position.value = from;
    segment = 0;
    approaching =
        !widget.reducedMotion &&
        !MediaQuery.disableAnimationsOf(context) &&
        (from - to).abs() > .001;
    setState(() {
      held = true;
      overridden = true;
      pending = null;
    });
    if (approaching) {
      settle.duration = const Duration(milliseconds: 120);
      settle.forward(from: 0);
    } else {
      position.value = to;
    }
  }

  void move(PointerMoveEvent details) {
    if (!held || details.pointer != pointer) return;
    if (approaching) {
      // Retarget from the actual painted position without restarting the
      // entry deadline. Repeated pointer events cannot prolong the catch-up.
      from = position.value;
      to = pageAt(details.localPosition);
      segment = Curves.easeOutCubic.transform(settle.value);
    } else {
      position.value = pageAt(details.localPosition);
    }
  }

  void finish(PointerUpEvent details) {
    if (!held || details.pointer != pointer) return;
    pointer = null;
    final height = context.size?.height ?? 0;
    final valid =
        details.localPosition.dy >= -48 &&
        details.localPosition.dy <= height + 48;
    final target = valid ? pageAt(details.localPosition).round() : widget.index;
    final token = ++revision;
    setState(() => held = false);
    snap(target);
    if (valid && target != widget.index) widget.onChanged(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != revision) return;
      if (overridden && pending != widget.index) snap(widget.index);
    });
  }

  void cancel() {
    if (!held) return;
    pointer = null;
    revision++;
    setState(() => held = false);
    snap(widget.index);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.progress?.removeListener(externalProgress);
    settle.dispose();
    position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: start,
    onPointerMove: move,
    onPointerUp: finish,
    onPointerCancel: (event) {
      if (event.pointer == pointer) cancel();
    },
    child: RawGestureDetector(
      key: const Key('navigation-scrub-area'),
      behavior: HitTestBehavior.opaque,
      // Own physical presses immediately, so retained button recognizers cannot
      // dispatch a second tap on release. Their semantic/keyboard actions stay.
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              () => EagerGestureRecognizer(
                allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
              ),
              (_) {},
            ),
      },
      child: Stack(
        children: [
          if (overridden || widget.progress != null)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: widget.itemWidth,
              child: ValueListenableBuilder<double>(
                valueListenable: overridden ? position : widget.progress!,
                child: widget.indicator,
                builder: (context, page, child) => Transform.translate(
                  offset: Offset(page.clamp(0, 3) * widget.itemWidth, 0),
                  child: child,
                ),
              ),
            )
          else
            AnimatedPositioned(
              duration: widget.reducedMotion
                  ? Duration.zero
                  : const Duration(milliseconds: 340),
              curve: Curves.easeInOutCubic,
              left: widget.index * widget.itemWidth,
              top: 0,
              bottom: 0,
              width: widget.itemWidth,
              child: widget.indicator,
            ),
          widget.child,
        ],
      ),
    ),
  );
}
