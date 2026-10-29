/// Values from this playback's MPV only. Missing values remain unknown.
class RuntimeSample {
  const RuntimeSample({
    required this.now,
    required this.position,
    required this.playing,
    required this.buffering,
    required this.seeking,
    required this.cachePaused,
    required this.outputReady,
    this.audioPosition,
    this.hardware = '',
  });
  final Duration now, position;
  final Duration? audioPosition;
  final bool playing, buffering, seeking, cachePaused, outputReady;
  final String hardware;
  bool get running => playing && !buffering && !seeking && !cachePaused;
}

enum RuntimeAction { none, recover, recovered, fail }

/// Require an advancing audio clock AND a stationary/regressed video-led
/// playhead. A still scene, frame drops, a texture, or cache size alone is not
/// evidence of this fault. Recovery never opens media or changes playback rate.
class RuntimeHealthWatch {
  RuntimeSample? _anchor;
  bool attempted = false, recovering = false;
  Duration? _recoverySince;
  Duration _target = Duration.zero;
  Duration _lastSample = Duration.zero, _activeRecovery = Duration.zero;
  bool _previousRunning = false;

  void reset() {
    attempted = recovering = false;
    _anchor = null;
    _recoverySince = null;
    _activeRecovery = Duration.zero;
    _previousRunning = false;
  }

  // User seeks cancel stale recovery verification, but not the one-attempt
  // budget of this media. Pausing/backgrounding never triggers a resume.
  void seek() {
    _anchor = null;
    recovering = false;
    _recoverySince = null;
    _previousRunning = false;
  }

  void beginRecovery(Duration target, Duration now) {
    attempted = recovering = true;
    _target = target;
    _recoverySince = now;
    _lastSample = now;
    _activeRecovery = Duration.zero;
    _previousRunning = false;
    _anchor = null;
  }

  RuntimeAction sample(RuntimeSample sample, {required double speed}) {
    if (recovering) {
      final elapsed = sample.now - _lastSample;
      _lastSample = sample.now;
      if (_previousRunning && sample.playing) _activeRecovery += elapsed;
      _previousRunning = sample.playing;
      final anchor = _anchor;
      if (sample.running &&
          sample.outputReady &&
          sample.hardware == 'no' &&
          sample.position >= _target &&
          anchor != null &&
          sample.position - anchor.position >=
              const Duration(milliseconds: 500) &&
          sample.audioPosition != null &&
          anchor.audioPosition != null &&
          sample.audioPosition! > anchor.audioPosition!) {
        recovering = false;
        _anchor = sample;
        return RuntimeAction.recovered;
      }
      if (sample.running && sample.position >= _target) _anchor ??= sample;
      if (_recoverySince != null &&
          _activeRecovery >= const Duration(seconds: 30)) {
        recovering = false;
        return RuntimeAction.fail;
      }
      return RuntimeAction.none;
    }
    if (!sample.running ||
        !sample.outputReady ||
        sample.audioPosition == null) {
      _anchor = null;
      return RuntimeAction.none;
    }
    final anchor = _anchor;
    if (anchor == null ||
        sample.position > anchor.position + const Duration(milliseconds: 100) ||
        sample.audioPosition! < anchor.audioPosition!) {
      _anchor = sample;
      return RuntimeAction.none;
    }
    if (sample.now - anchor.now < const Duration(seconds: 6) ||
        sample.audioPosition! - anchor.audioPosition! <
            const Duration(seconds: 1)) {
      return RuntimeAction.none;
    }
    _anchor = null;
    if (!attempted && speed > 2 && sample.hardware.startsWith('mediacodec')) {
      return RuntimeAction.recover;
    }
    return RuntimeAction.fail;
  }
}

Duration? mediaClock(String? value) {
  final seconds = double.tryParse(value ?? '');
  if (seconds == null || !seconds.isFinite || seconds < 0 || seconds > 1e9) {
    return null;
  }
  return Duration(microseconds: (seconds * 1000000).round());
}
