import 'runtime_health.dart';

/// Current-player observations only; untagged native logs cannot establish a
/// later load's identity. A ready synchronized frame can be retained while its
/// cache is paused, but only uninterrupted running samples can prove a fault.
class DiscClockRecoveryEvidence {
  int? _load, _epoch, _intent;
  RuntimeSample? _baseline, _first, _last;
  int _samples = 0;

  void clear() {
    _load = _epoch = _intent = null;
    _baseline = _first = _last = null;
    _samples = 0;
  }

  void begin({required int load, required int epoch, required int intent}) {
    clear();
    _load = load;
    _epoch = epoch;
    _intent = intent;
  }

  bool _current(int load, int epoch, int intent) =>
      load == _load && epoch == _epoch && intent == _intent;

  void _cancelRun() {
    _first = _last = null;
    _samples = 0;
  }

  void observe(
    RuntimeSample sample, {
    required int load,
    required int epoch,
    required int intent,
    required bool selectedOrdinaryDisc,
  }) {
    if (!_current(load, epoch, intent)) return;
    if (!selectedOrdinaryDisc) {
      _baseline = null;
      _cancelRun();
      return;
    }
    final audio = sample.audioPosition;
    if (!sample.playing ||
        sample.seeking ||
        !sample.outputReady ||
        !const {'mediacodec', 'mediacodec-copy'}.contains(sample.hardware) ||
        audio == null ||
        audio.isNegative ||
        sample.position.isNegative) {
      _cancelRun();
      return;
    }
    final baseline = _baseline;
    if (baseline != null && sample.now <= baseline.now) return;
    final last = _last;
    if (last != null && sample.now <= last.now) return;
    if ((sample.position - audio).abs() <= const Duration(seconds: 1) &&
        sample.position > const Duration(seconds: 3)) {
      _baseline = sample;
      _cancelRun();
      return;
    }
    if (!sample.running ||
        baseline == null ||
        sample.hardware != baseline.hardware ||
        sample.now - baseline.now > const Duration(seconds: 30) ||
        sample.position > const Duration(milliseconds: 100) ||
        baseline.position - sample.position <= const Duration(seconds: 3) ||
        audio < baseline.audioPosition!) {
      _cancelRun();
      return;
    }
    if (last != null &&
        (sample.now - last.now > const Duration(seconds: 5) ||
            audio < last.audioPosition!)) {
      _cancelRun();
    }
    _first ??= sample;
    _last = sample;
    _samples++;
  }

  bool qualifies({
    required int load,
    required int epoch,
    required int intent,
    required Duration now,
    required String hardware,
  }) {
    final first = _first, last = _last;
    return _current(load, epoch, intent) &&
        first != null &&
        last != null &&
        _samples >= 2 &&
        now >= last.now &&
        now - last.now <= const Duration(seconds: 4) &&
        hardware == last.hardware &&
        last.now - first.now >= const Duration(seconds: 6) &&
        last.audioPosition! - first.audioPosition! >=
            const Duration(seconds: 1);
  }
}
