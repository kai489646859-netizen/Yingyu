/// A decoder reset is not a user seek. Keep the last observed media position;
/// never advance it using wall time or take the maximum across real seeks.
class PlaybackPositionGuard {
  Duration value = Duration.zero;
  bool rejected = false;
  Duration? _seekTarget;
  bool get settling => _seekTarget != null;

  void reset(Duration position) {
    value = position;
    rejected = false;
    _seekTarget = null;
  }

  void beginSeek(Duration target) {
    reset(target);
    _seekTarget = target;
  }

  bool accept(Duration position, {Duration duration = Duration.zero}) {
    final target = _seekTarget;
    if (target != null) {
      if ((position - target).abs() > const Duration(seconds: 3)) return false;
      _seekTarget = null;
    }
    rejected =
        position.isNegative ||
        value - position > const Duration(seconds: 3) ||
        (duration > Duration.zero &&
            position > duration + const Duration(seconds: 2));
    if (!rejected) value = position;
    return !rejected;
  }
}
