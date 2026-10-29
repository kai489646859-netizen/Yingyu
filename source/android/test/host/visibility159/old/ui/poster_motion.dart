import 'package:flutter/widgets.dart';

/// Keep the existing list keys and widget interfaces, without motion state,
/// scroll listeners, geometry checks, tickers, opacity layers or transforms.
class PosterMotionScope extends StatelessWidget {
  const PosterMotionScope({
    super.key,
    required this.child,
    this.reducedMotion = false,
    this.active = true,
  });
  final Widget child;
  final bool reducedMotion, active;
  @override
  Widget build(BuildContext context) => child;
}

class PosterEntrance extends StatelessWidget {
  const PosterEntrance({
    super.key,
    required this.id,
    required this.child,
    this.active = true,
    this.axis = Axis.vertical,
  });
  final String id;
  final Widget child;
  final bool active;
  final Axis axis;
  @override
  Widget build(BuildContext context) => child;
}

/// Retained notification type for callers; images no longer dispatch it.
class PosterImageStatus extends Notification {
  const PosterImageStatus({required this.ready});
  final bool ready;
}
