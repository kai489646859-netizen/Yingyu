import 'runtime_health.dart';

enum HardwareRepairAction { none, retryHardware, cleanSoftware, verified }

/// A runtime MediaCodec failure is different from an unsupported codec during
/// opening. Only a decoder already observed producing output earns one retry.
/// The fixed MPV only replays startup packets on native fallback: after its
/// first output, a software decoder can resume without the needed references.
class HardwareFallbackWatch {
  String? hardware;
  bool retried = false, softwareCleaned = false;
  bool _fault = false, _verifying = false;
  RuntimeSample? _healthyAfterFault;
  RuntimeSample? _anchor;
  int _generation = 0;
  int get generation => _generation;

  void reset() {
    hardware = null;
    retried = softwareCleaned = false;
    cancel();
  }

  /// Manual seeks and intentional software recovery supersede an old fault.
  /// They never replenish the retry budget for this media.
  void cancel() {
    _generation++;
    _fault = _verifying = false;
    _healthyAfterFault = null;
    _anchor = null;
  }

  void observeHardware(String value) {
    if (const {'mediacodec', 'mediacodec-copy'}.contains(value)) {
      hardware = value;
    }
  }

  bool fault(String prefix, String level, String text) {
    if (hardware == null ||
        softwareCleaned ||
        !isRuntimeHardwareFailure(prefix, level, text)) {
      return false;
    }
    _fault = true;
    _healthyAfterFault = null;
    _anchor = null;
    return true;
  }

  HardwareRepairAction sample(RuntimeSample value) {
    if (value.outputReady) observeHardware(value.hardware);
    // A missing property, pause, seek or network stall is not a decoder fault.
    if (!value.playing || value.seeking) return HardwareRepairAction.none;
    if (_fault &&
        value.running &&
        value.outputReady &&
        value.hardware == hardware) {
      final healthy = _healthyAfterFault;
      if (healthy != null &&
          value.position - healthy.position >=
              const Duration(milliseconds: 500) &&
          value.audioPosition != null &&
          healthy.audioPosition != null &&
          value.audioPosition! > healthy.audioPosition!) {
        _fault = false;
      }
      _healthyAfterFault = value;
    }
    // Pausing/backgrounding cannot age away an actual failure. Only fresh
    // advancing hardware output, a manual seek or a new media cancels it.
    if (_fault && value.hardware == 'no') {
      _fault = false;
      _verifying = true;
      _anchor = null;
      if (!retried) {
        retried = true;
        return HardwareRepairAction.retryHardware;
      }
      if (!softwareCleaned) {
        softwareCleaned = true;
        return HardwareRepairAction.cleanSoftware;
      }
    }
    if (!_verifying || !value.running || !value.outputReady) {
      _anchor = null;
      return HardwareRepairAction.none;
    }
    // A rejected hardware rebuild may initialize software without another
    // warning. Two ready software samples also require a clean keyframe seek.
    final anchor = _anchor;
    if (!softwareCleaned &&
        value.hardware == 'no' &&
        anchor?.hardware == 'no' &&
        value.now - anchor!.now >= const Duration(seconds: 1)) {
      softwareCleaned = true;
      _anchor = null;
      return HardwareRepairAction.cleanSoftware;
    }
    final expected = softwareCleaned
        ? value.hardware == 'no'
        : const {'mediacodec', 'mediacodec-copy'}.contains(value.hardware);
    if (expected &&
        anchor != null &&
        anchor.hardware == value.hardware &&
        value.position - anchor.position >= const Duration(milliseconds: 500) &&
        value.audioPosition != null &&
        anchor.audioPosition != null &&
        value.audioPosition! > anchor.audioPosition!) {
      _verifying = false;
      _anchor = null;
      return HardwareRepairAction.verified;
    }
    _anchor = value;
    return HardwareRepairAction.none;
  }
}

bool isRuntimeHardwareFailure(String prefix, String level, String text) {
  if (!const {'warn', 'error', 'fatal'}.contains(level)) return false;
  if (prefix == 'vd') {
    return RegExp(
      r'^Attempting next decoding method after failure of (?:[a-z0-9_]{1,40}-)?mediacodec(?:-copy)?\.$',
    ).hasMatch(text.trim());
  }
  if (!RegExp(r'^ffmpeg/video(?:/|$)').hasMatch(prefix)) return false;
  return RegExp(
    r'Failed to (?:dequeue (?:input|output) buffer \(status\s*=\s*-?\d+\)|queue input (?:empty )?buffer \(status\s*=\s*-?\d+\)|flush codec|wrap MediaCodec buffer)',
  ).hasMatch(text);
}

/// Commands are shared by production and synthetic native substitutes. The
/// owner serializes them with speed/seek; lifecycle checks run after each await.
/// MPV's UPDATE_HWDEC rebuilds the decoder and clears its attempted-method list.
/// An exact seek decodes from a keyframe to the preserved checkpoint, flushing
/// missing references. It does not open a URL, play, pause or alter track/rate.
Future<void> repairHardwareFallback({
  required HardwareRepairAction action,
  required String hardware,
  required Duration position,
  required bool Function() active,
  required Future<void> Function(String, String) write,
  required Future<void> Function(Duration) seek,
}) async {
  if (!active()) return;
  if (action == HardwareRepairAction.retryHardware) {
    if (!const {'mediacodec', 'mediacodec-copy'}.contains(hardware)) {
      throw StateError('Unverified hardware decoder');
    }
    await write('hwdec', hardware).timeout(const Duration(seconds: 3));
  } else if (action != HardwareRepairAction.cleanSoftware) {
    return;
  }
  if (!active()) return;
  await seek(position).timeout(const Duration(seconds: 3));
}
