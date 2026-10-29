import 'dolby_source.dart';
import 'runtime_health.dart';

enum DolbyRecoveryAction { none, rebuildHardware, recovered, fail }

/// One retry of a generic mapper failure during an explicit user seek.
///
/// This never changes timestamps, pairs metadata, opens media, starts playback,
/// or performs a command. The backend owns the serialized hardware rebuild and
/// exact seek. Definite pairing/capability errors always remain fatal.
class DolbySeekRecovery {
  DolbySeekRecovery({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;
  int _generation = 0;
  bool attempted = false;
  bool _seekOpen = false, _pending = false, _started = false;
  bool _repairing = false, _completed = false, _restarted = false;
  bool _wasPlaying = false;
  Duration _target = Duration.zero;
  Duration _activeSeek = Duration.zero, _activeRecovery = Duration.zero;
  Duration _lastNow = Duration.zero;
  double _maximumSpeed = 1;
  String _hardware = '';
  RuntimeSample? _anchor, _lastReady;

  int get generation => _generation;

  /// While true this watch owns the original seek's non-paused time budget.
  /// The backend must not also expire this seek using an older wall clock.
  bool get trackingSeek => _seekOpen;
  bool get recovering => _pending;
  bool get repairing => _repairing;
  Duration get target => _target;
  String get hardware => _hardware;

  /// Only a new media resets the single retry budget. A new user seek cancels
  /// stale queued work but cannot replenish a retry already spent.
  void reset() {
    cancel();
    attempted = false;
    _hardware = '';
    _target = Duration.zero;
  }

  void cancel() {
    _generation++;
    _seekOpen = _pending = _started = _repairing = _completed = false;
    _restarted = _wasPlaying = false;
    _anchor = _lastReady = null;
    _activeSeek = _activeRecovery = Duration.zero;
  }

  int beginSeek({
    required Duration target,
    required Duration now,
    required String hardware,
    required bool playing,
    double speed = 1,
  }) {
    cancel();
    _target = target;
    _hardware = hardware;
    _lastNow = now;
    _wasPlaying = playing;
    _maximumSpeed = 0;
    observeSpeed(speed);
    if (_maximumSpeed == 0) _maximumSpeed = 1;
    _seekOpen = !target.isNegative;
    return _generation;
  }

  /// Observe only a speed confirmed by the player. A later decrease must not
  /// make valid output from the earlier, faster part exceed the target bound.
  void observeSpeed(double speed) {
    if (speed.isFinite && speed > 0 && speed <= 16 && speed > _maximumSpeed) {
      _maximumSpeed = speed;
    }
  }

  void _tick(Duration now, bool playing) {
    if (now < _lastNow) return;
    final elapsed = now - _lastNow;
    // A gap that includes a pause/resume transition is not assumed to be
    // playback time. Paused and background intervals cannot consume the limit.
    if (_wasPlaying && playing) {
      if (_seekOpen) _activeSeek += elapsed;
      if (_pending) _activeRecovery += elapsed;
    }
    _lastNow = now;
    _wasPlaying = playing;
  }

  /// Split the budget at an actual player-state event, including transitions
  /// between two slow property probes. This observes playback; it never starts
  /// or resumes it. Keep the interval before the event in the prior state.
  void playbackChanged({required Duration now, required bool playing}) {
    if (now < _lastNow) return;
    _tick(now, _wasPlaying);
    _wasPlaying = playing;
    if (!playing) _anchor = _lastReady = null;
  }

  DolbyRecoveryAction _fail() {
    cancel();
    return DolbyRecoveryAction.fail;
  }

  DolbyRecoveryAction fault(
    DolbyOutputFailure issue, {
    required Duration now,
    required bool opening,
    required String currentHardware,
    required bool playing,
  }) {
    if (issue == DolbyOutputFailure.none) return DolbyRecoveryAction.none;
    _tick(now, playing);
    if (issue != DolbyOutputFailure.mapping) return _fail();
    if (opening ||
        !_seekOpen ||
        _activeSeek >= timeout ||
        !const {'mediacodec', 'mediacodec-copy'}.contains(_hardware) ||
        currentHardware != _hardware) {
      return _fail();
    }
    if (_pending) {
      if (_activeRecovery >= timeout) return _fail();
      // Several old frame callbacks may already be queued when the first
      // fault schedules a rebuild. Coalesce those only until commands finish.
      // A later mapper error after that single rebuild is still a real failure.
      return _completed ? _fail() : DolbyRecoveryAction.none;
    }
    if (attempted) return _fail();
    attempted = true;
    _pending = true;
    _activeRecovery = Duration.zero;
    _anchor = _lastReady = null;
    return DolbyRecoveryAction.rebuildHardware;
  }

  bool repairStarted({required int generation, required Duration now}) {
    if (generation != _generation || !_pending || _started) return false;
    // Preserve the timeout accumulated since the actual failure. Commands and
    // repeated warnings never start a new recovery budget.
    if (now > _lastNow) _tick(now, _wasPlaying);
    if (_activeSeek >= timeout || _activeRecovery >= timeout) return false;
    _started = _repairing = true;
    _completed = _restarted = false;
    _anchor = _lastReady = null;
    return true;
  }

  void repairCompleted({required int generation}) {
    if (generation != _generation || !_pending || !_started) return;
    _repairing = false;
    _completed = true;
  }

  void restarted() {
    if (!_seekOpen || _pending && !_started) return;
    _restarted = true;
    _anchor = _lastReady = null;
  }

  bool _atTarget(RuntimeSample sample, double speed) {
    final audio = sample.audioPosition;
    if (!speed.isFinite ||
        speed <= 0 ||
        speed > 16 ||
        audio == null ||
        audio.isNegative ||
        sample.position.isNegative) {
      return false;
    }
    // This checks observed clocks only; it does not relax or replace native
    // PTS/AImage/RPU matching. The upper bound prevents an old far-ahead frame
    // from validating a backwards seek merely because position >= target.
    final active = _pending ? _activeRecovery : _activeSeek;
    final upper =
        _target +
        Duration(microseconds: (active.inMicroseconds * _maximumSpeed).ceil()) +
        const Duration(seconds: 1);
    return sample.position >= _target - const Duration(milliseconds: 250) &&
        sample.position <= upper &&
        audio >= _target - const Duration(seconds: 1) &&
        audio <= upper + const Duration(seconds: 1) &&
        (sample.position - audio).abs() <= const Duration(seconds: 1);
  }

  DolbyRecoveryAction sample(
    RuntimeSample sample, {
    required int generation,
    required double speed,
  }) {
    if (generation != _generation || !_seekOpen) {
      return DolbyRecoveryAction.none;
    }
    observeSpeed(speed);
    _tick(sample.now, sample.playing);
    if (_pending && (_activeRecovery >= timeout || _activeSeek >= timeout)) {
      return _fail();
    }
    if (!_pending && _activeSeek >= timeout) {
      // No mapping fault occurred: the existing seek deadline remains in
      // charge. Do not retain a retry window for an unrelated later failure.
      cancel();
      return DolbyRecoveryAction.none;
    }
    if (!_restarted ||
        _pending && !_completed ||
        !sample.running ||
        !sample.outputReady ||
        sample.hardware != _hardware ||
        !_atTarget(sample, speed)) {
      _anchor = _lastReady = null;
      return DolbyRecoveryAction.none;
    }
    final anchor = _anchor;
    final previous = _lastReady;
    if (previous != null && sample.now <= previous.now) {
      return DolbyRecoveryAction.none;
    }
    _lastReady = sample;
    if (anchor == null ||
        previous != null &&
            (sample.position < previous.position ||
                sample.audioPosition! < previous.audioPosition!)) {
      _anchor = sample;
      return DolbyRecoveryAction.none;
    }
    if (sample.position - anchor.position < const Duration(milliseconds: 500) ||
        sample.audioPosition! <= anchor.audioPosition!) {
      return DolbyRecoveryAction.none;
    }
    final recovered = _pending;
    cancel();
    return recovered ? DolbyRecoveryAction.recovered : DolbyRecoveryAction.none;
  }
}
