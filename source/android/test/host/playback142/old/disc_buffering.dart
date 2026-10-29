/// MPV expresses these thresholds in media seconds, not wall-clock seconds.
/// Keep the normal two-second playback cushion. Above 2x, accumulate eight
/// seconds of playback before restarting an empty cache, so a cold seek does
/// not repeatedly restart with only two seconds of protection against jitter.
/// This changes MPV's restart threshold, not playback rate, byte limits or the
/// trigger for interrupting running playback. MPV resumes when its reader is
/// idle (including a full cache or EOF), even below the requested duration.
Map<String, String> discBufferOptions(double speed, {int? forwardBytes}) => {
  'cache': 'yes',
  'cache-pause': 'yes',
  'cache-pause-initial': 'yes',
  'cache-pause-wait': ((speed > 2 ? 8 : 2) * speed)
      .clamp(1, 24)
      .toStringAsFixed(2),
  'cache-secs': (speed > 2 ? 180.0 : (20 * speed).clamp(10, 60))
      .toStringAsFixed(2),
  if (forwardBytes != null) 'demuxer-max-bytes': '$forwardBytes',
};

/// Preserve the normal-speed budget. High speed can retain approximately the
/// same wall-clock cushion, with a separate cap for the existing memory tiers.
/// Low-memory devices never grow; these are packet bytes, not total process RAM.
int discForwardBufferBytes(
  int baseBytes,
  double speed,
  int memoryMiB, {
  int? previousBytes,
}) {
  final cap = (memoryMiB <= 32
      ? baseBytes
      : memoryMiB >= 128
      ? 768 * 1024 * 1024
      : 384 * 1024 * 1024);
  final requested =
      (baseBytes *
              (speed > 2
                  ? 6
                  : speed > 1
                  ? speed * 1.5
                  : 1))
          .round();
  final retained = previousBytes ?? baseBytes;
  return (requested > retained ? requested : retained).clamp(
    baseBytes,
    cap < baseBytes ? baseBytes : cap,
  );
}

/// Preserve gesture/menu order even when setting native options is asynchronous.
class PlaybackRateQueue {
  PlaybackRateQueue(this.apply);
  final Future<void> Function(double) apply;
  Future<void> _tail = Future.value();
  Future<void> set(double value) => run(() => apply(value));
  Future<void> run(Future<void> Function() work) {
    final result = _tail.then((_) => work());
    // Report this request's error to its caller; allow the next rate to proceed.
    _tail = result.catchError((Object _) {});
    return result;
  }
}

class DiscBufferWatch {
  Duration? _since, _position;
  bool _reported = false;
  void reset() {
    _since = _position = null;
    _reported = false;
  }

  bool sample({
    required Duration now,
    required Duration position,
    required bool playing,
    required bool buffering,
    required bool completed,
  }) {
    if (!playing || !buffering || completed) {
      reset();
      return false;
    }
    if (_position != position || _since == null) {
      _since = now;
      _position = position;
      _reported = false;
    }
    if (!_reported && now - _since! >= const Duration(seconds: 60)) {
      _reported = true;
      return true;
    }
    return false;
  }
}
