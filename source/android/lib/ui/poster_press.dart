import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Raw pointer observation never competes with the card or scroll gesture arena.
class PosterPressFeedback extends StatefulWidget {
  const PosterPressFeedback({
    super.key,
    required this.child,
    this.active = true,
    this.builder,
  });
  final Widget child;
  final bool active;
  final Widget Function(BuildContext, bool, Widget)? builder;
  @override
  State<PosterPressFeedback> createState() => _PosterPressFeedbackState();
}

class _PosterPressFeedbackState extends State<PosterPressFeedback> {
  int? pointer;
  Offset origin = Offset.zero;
  void clear() {
    if (mounted && pointer != null) setState(() => pointer = null);
  }

  @override
  void didUpdateWidget(covariant PosterPressFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) pointer = null;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      if (pointer != null) {
        clear();
        return;
      }
      if (!widget.active || event.buttons & kPrimaryButton == 0) return;
      origin = event.position;
      setState(() => pointer = event.pointer);
    },
    onPointerMove: (event) {
      if (event.pointer == pointer &&
          (event.position - origin).distance > kTouchSlop) {
        clear();
      }
    },
    onPointerUp: (_) => clear(),
    onPointerCancel: (_) => clear(),
    child:
        widget.builder?.call(context, pointer != null, widget.child) ??
        Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            if (pointer != null)
              const Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    key: Key('poster-pressed'),
                    color: Color(0x33000000),
                  ),
                ),
              ),
          ],
        ),
  );
}
