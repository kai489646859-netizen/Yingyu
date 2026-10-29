import 'runtime_health.dart';

/// ad_lavc emits this for a rejected packet/frame. The pinned MPV's
/// lavc_process continues; END_FILE/ERROR is the terminal signal. Require
/// fresh, advancing A/V output before treating a single packet fault as passed.
bool isAudioPacketError(String prefix, String level, String text) =>
    prefix == 'ad' &&
    level == 'error' &&
    text.trim() == 'Error decoding audio.';

enum AudioDecodeAction { none, verified, fail }

class AudioDecodeWatch {
  bool pending = false;
  int errors = 0;
  Duration _last = Duration.zero, _active = Duration.zero;
  bool _playing = false;
  RuntimeSample? _anchor;
  bool _trackSwitch = false;
  bool _trackRejected = false;
  bool get trackSwitchHeld => _trackSwitch;
  bool get trackSwitchRejected => _trackRejected;
  void rejectTrackSwitch() {
    if (_trackSwitch) _trackRejected = true;
  }

  void holdForTrackSwitch(bool value) {
    _trackSwitch = value;
    _trackRejected = false;
    suspend();
  }

  /// Repeated errors neither restart the deadline nor reuse pre-error clocks.
  void fault(Duration now, {required bool playing}) {
    if (!pending) {
      _active = Duration.zero;
      _last = now;
      _playing = playing;
      errors = 0;
    }
    pending = true;
    errors++;
    _anchor = null;
  }

  void cancel() {
    _trackRejected = false;
    pending = false;
    errors = 0;
    _anchor = null;
  }

  void suspend() {
    _playing = false;
    _anchor = null;
  }

  AudioDecodeAction sample(
    RuntimeSample value, {
    bool videoRecovering = false,
  }) {
    if (!pending || _trackSwitch) return AudioDecodeAction.none;
    // Input waits are not opportunities for decoding to recover. Buffer events
    // suspend the interval between periodic samples as well.
    if (_playing && value.running && value.now > _last) {
      _active += value.now - _last;
    }
    _last = value.now;
    _playing = value.running;
    // A video fault must be allowed to finish its existing bounded recovery.
    // Keep this audio fault pending; no success is inferred from the command.
    // Repeated audio errors remain immediately fatal even during recovery.
    if (errors >= 8 ||
        (!videoRecovering && _active >= const Duration(seconds: 8))) {
      cancel();
      return AudioDecodeAction.fail;
    }
    if (!value.running || !value.outputReady || value.audioPosition == null) {
      _anchor = null;
      return AudioDecodeAction.none;
    }
    final anchor = _anchor;
    if (anchor != null &&
        value.position - anchor.position >= const Duration(milliseconds: 500) &&
        value.audioPosition! - anchor.audioPosition! >=
            const Duration(milliseconds: 500)) {
      cancel();
      return AudioDecodeAction.verified;
    }
    // Decoder recovery can seek both clocks back to the last good position.
    // A pre-seek audio clock must not prevent fresh post-seek A/V verification.
    if (anchor == null ||
        value.position < anchor.position ||
        value.audioPosition! < anchor.audioPosition!) {
      _anchor = value;
    }
    return AudioDecodeAction.none;
  }
}
