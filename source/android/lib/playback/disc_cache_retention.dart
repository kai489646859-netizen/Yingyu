import 'dart:async';
import 'disc_buffer_phase.dart';

/// Only prefetch capacity has hysteresis; this class cannot set playback rate.
/// Generation checks also invalidate an expiry queued behind native work.
class DiscCacheRetention {
  DiscCacheRetention(this.release);
  static const delay = Duration(seconds: 2);
  final void Function(int generation, double tier) release;
  Timer? _timer;
  int _generation = 0;

  bool isCurrent(int generation) => generation == _generation;

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void afterRate(DiscBufferPlan? plan, double speed) {
    cancel();
    if (plan == null || plan.fast || plan.tier <= discBufferTier(speed)) return;
    final target = discBufferTier(speed);
    final nextTier = plan.tier - 1 < target ? target : plan.tier - 1;
    final generation = _generation;
    _timer = Timer(delay, () {
      _timer = null;
      if (isCurrent(generation)) release(generation, nextTier);
    });
  }
}
