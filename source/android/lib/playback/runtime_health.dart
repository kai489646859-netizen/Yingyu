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

/// Loss of the whole output is different from a stationary video clock.
/// Count only running samples with a positive missing-output observation and
/// advancing audio; a read failure, pause, seek or cache pause is not evidence.
class VideoOutputLossWatch {
  RuntimeSample? _first, _last;
  Duration _elapsed = Duration.zero;
  bool _expected = false;
  void reset({bool expectedVideo = false}) {
    _first = _last = null;
    _elapsed = Duration.zero;
    _expected = expectedVideo;
  }

  bool sample(RuntimeSample value, {required bool outputMissing}) {
    if (!_expected ||
        !value.running ||
        !outputMissing ||
        value.audioPosition == null) {
      _first = _last = null;
      _elapsed = Duration.zero;
      return false;
    }
    final previous = _last;
    if (previous == null || value.audioPosition! <= previous.audioPosition!) {
      _first = _last = value;
      _elapsed = Duration.zero;
      return false;
    }
    final interval = value.now - previous.now;
    if (interval.isNegative || interval > const Duration(seconds: 4)) {
      _first = _last = value;
      _elapsed = Duration.zero;
      return false;
    }
    _elapsed += interval;
    _last = value;
    return _elapsed >= const Duration(seconds: 6) &&
        value.audioPosition! - _first!.audioPosition! >=
            const Duration(seconds: 1);
  }
}

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
  String _expectedHardware = 'no';
  bool _synchronizedAv = false;
  RuntimeSample? _lastRecoverySample;
  int _readyIntervals = 0;
  double? _recoverySpeed;
  double _maximumRecoverySpeed = 0;

  void reset() {
    attempted = recovering = false;
    _anchor = null;
    _recoverySince = null;
    _activeRecovery = Duration.zero;
    _previousRunning = false;
    _lastRecoverySample = null;
    _readyIntervals = 0;
    _recoverySpeed = null;
    _maximumRecoverySpeed = 0;
  }

  // User seeks cancel stale recovery verification, but not the one-attempt
  // budget of this media. Pausing/backgrounding never triggers a resume.
  void seek() {
    _anchor = null;
    recovering = false;
    _recoverySince = null;
    _previousRunning = false;
    _lastRecoverySample = null;
    _readyIntervals = 0;
  }

  void beginRecovery(
    Duration target,
    Duration now, {
    String hardware = 'no',
    bool requireSynchronizedAv = false,
    double speed = 1,
  }) {
    attempted = recovering = true;
    _target = target;
    _recoverySince = now;
    _lastSample = now;
    _activeRecovery = Duration.zero;
    _previousRunning = false;
    _anchor = null;
    _expectedHardware = hardware;
    _synchronizedAv = requireSynchronizedAv;
    _lastRecoverySample = null;
    _readyIntervals = 0;
    _recoverySpeed = null;
    _maximumRecoverySpeed = 0;
    observeSpeed(speed);
  }

  /// Call only after the native rate command has succeeded. A high confirmed
  /// rate before/between probes still bounds later output after a decrease.
  void observeSpeed(double speed) {
    if (!recovering ||
        !_synchronizedAv ||
        !speed.isFinite ||
        speed <= 0 ||
        speed > 16) {
      return;
    }
    if (speed > _maximumRecoverySpeed) _maximumRecoverySpeed = speed;
    if (_recoverySpeed != speed) {
      _anchor = null;
      _lastRecoverySample = null;
      _readyIntervals = 0;
      _recoverySpeed = speed;
    }
  }

  bool _synchronizedSample(RuntimeSample sample, double speed) {
    final previous = _lastRecoverySample;
    if (speed.isFinite && speed > _maximumRecoverySpeed && speed <= 16) {
      _maximumRecoverySpeed = speed;
    }
    final upper =
        _target +
        Duration(
          // Only a generous upper sanity bound uses elapsed wall time. The
          // first property probe may arrive late; it is not zero playback.
          // Pausing can widen this bound but never extends _activeRecovery.
          microseconds:
              ((sample.now - (_recoverySince ?? sample.now)).inMicroseconds *
                      _maximumRecoverySpeed)
                  .ceil(),
        ) +
        const Duration(seconds: 1);
    if (!speed.isFinite ||
        speed <= 0 ||
        speed > 16 ||
        sample.audioPosition == null ||
        sample.position > upper ||
        sample.audioPosition! > upper + const Duration(seconds: 1) ||
        (sample.position - sample.audioPosition!).abs() >
            const Duration(seconds: 1)) {
      _lastRecoverySample = null;
      _readyIntervals = 0;
      return false;
    }
    if (previous != null && sample.now <= previous.now) return false;
    _lastRecoverySample = sample;
    final sameSpeed = _recoverySpeed == speed;
    _recoverySpeed = speed;
    if (previous == null || !sameSpeed) {
      _readyIntervals = 0;
      return false;
    }
    final elapsed = sample.now - previous.now;
    final expected = elapsed.inMicroseconds * speed;
    final video = sample.position - previous.position;
    final audio = sample.audioPosition! - previous.audioPosition!;
    // Defer confirmation for large drift, clock resets, or grossly slower
    // output. This is a generous continuity floor, not a claim of exact device
    // throughput. Both intervals use actual sample time and confirmed speed.
    if (elapsed > const Duration(seconds: 5) ||
        video.inMicroseconds < expected * .5 ||
        audio.inMicroseconds < expected * .5 ||
        (video - audio).abs().inMicroseconds > 250000 + expected * .2) {
      _readyIntervals = 0;
      return false;
    }
    return ++_readyIntervals >= 2;
  }

  RuntimeAction sample(RuntimeSample sample, {required double speed}) {
    if (recovering) {
      final elapsed = sample.now - _lastSample;
      _lastSample = sample.now;
      if (_previousRunning && sample.playing) _activeRecovery += elapsed;
      _previousRunning = sample.playing;
      final anchor = _anchor;
      final ready =
          sample.running &&
          sample.outputReady &&
          sample.hardware == _expectedHardware &&
          sample.position >= _target &&
          sample.audioPosition != null;
      if (!ready) {
        _anchor = null;
        _lastRecoverySample = null;
        _readyIntervals = 0;
      } else if (anchor != null &&
          sample.position - anchor.position >=
              const Duration(milliseconds: 500) &&
          sample.audioPosition! > anchor.audioPosition! &&
          (!_synchronizedAv || _synchronizedSample(sample, speed))) {
        recovering = false;
        _anchor = sample;
        return RuntimeAction.recovered;
      } else if (anchor == null ||
          sample.position < anchor.position ||
          sample.audioPosition! < anchor.audioPosition!) {
        // Both ends must be fresh output from the expected decoder. A missing
        // audio clock cannot become a permanent anchor, and a decoder clock
        // reset must establish a new pair before confirming recovery.
        _anchor = sample;
        if (_synchronizedAv) _synchronizedSample(sample, speed);
      }
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
    if (!attempted && sample.hardware.startsWith('mediacodec')) {
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
