import 'dart:math' as math;

/// Local to the danmaku layer. Never writes back to the player.
class DanmakuClock {
  static const _predictionLimit = .8;
  static const _frameLimit = .05;

  double _value = 0;
  double get value => _value;
  int _revision = -1;
  double _sample = 0, _sampleAt = 0;
  double _frameAt = 0, _rate = 1, _target = 0;
  bool _running = false, _paced = false, _seeking = false;

  void idle() => _revision = -1;

  /// Returns true when the overlay must discard pre-seek flights.
  bool update({
    required double now,
    required double position,
    required double speed,
    required bool running,
    required int revision,
    bool seeking = false,
  }) {
    final resumed = running && !_running;
    final seekSettled = _seeking && !seeking;
    _seeking = seeking;
    _running = running;
    final before = _frameAt, previousRate = _rate;
    _frameAt = now;
    _rate = speed;
    _paced |= speed > 1;
    if (_revision != revision ||
        seekSettled ||
        (!_paced && (position - value).abs() > 1)) {
      _revision = revision;
      _paced = speed > 1;
      _sample = _target = _value = position;
      _sampleAt = now;
      return true;
    }
    if (!running) return false;
    final fresh = position != _sample || resumed;
    if (fresh) {
      _sample = position;
      _sampleAt = now;
      _target = position;
    }
    if (!_paced) {
      _value = math.max(
        value,
        position + math.min(now - _sampleAt, .22) * speed,
      );
      _target = _value;
      return false;
    }
    if (resumed) return false;

    // Rate changes only affect elapsed time after the change. A delayed
    // report moves the target, never the already rendered clock.
    final deadline = _sampleAt + _predictionLimit;
    final elapsed = math.max(0.0, math.min(now, deadline) - before);
    if (!fresh) _target += elapsed * previousRate;
    final step = math.min(elapsed, _frameLimit);
    final error = _target - (value + step * previousRate);
    final correction = error.sign * math.max(0.0, error.abs() - .025) / .8;
    final rate =
        previousRate +
        correction.clamp(-.20 * previousRate, .20 * previousRate);
    _value += step * rate;
    return false;
  }
}
