import 'dart:async';

/// All fields are read from the existing MPV instance, never a second probe.
class VideoOutputState {
  const VideoOutputState({
    required this.output,
    required this.configured,
    required this.frameAvailable,
    required this.seeking,
    required this.hardwareDecoder,
  });
  final String output, hardwareDecoder;
  final bool configured, frameAvailable, seeking;

  // Dimensions and hwdec-current=no alone can precede the first decoded frame.
  bool get ready =>
      output.isNotEmpty &&
      output != 'null' &&
      configured &&
      frameAvailable &&
      !seeking &&
      hardwareDecoder.isNotEmpty;
}

/// Waits for MPV's restart event plus a current frame in its real video output.
/// Also bounds codec recovery after opening, including Android surface rebuilds.
/// It never reopens media, changes a decoder option, seeks, or resumes playback.
class DecoderRecovery {
  DecoderRecovery({
    required this.readOutput,
    required this.onFailure,
    required this.onRecovered,
    this.recoveryTimeout = const Duration(seconds: 30),
    this.sampleInterval = const Duration(milliseconds: 100),
  });

  final Future<VideoOutputState> Function() readOutput;
  final void Function(String) onFailure;
  final void Function(VideoOutputState) onRecovered;
  final Duration recoveryTimeout, sampleInterval;
  Completer<void>? _opening;
  Timer? _poll, _deadline;
  int _epoch = 0;
  bool _active = false, _restarted = false, _busy = false;
  String? _pendingError;

  Future<void> beginLoad() {
    cancel();
    _active = true;
    _opening = Completer<void>();
    // Cancellation can precede the caller awaiting this during disc detection.
    unawaited(_opening!.future.catchError((Object _) {}));
    _startPolling();
    return _opening!.future;
  }

  void outputChanged() {
    ++_epoch;
    _restarted = false;
  }

  void restarted() {
    if (!_active) return;
    _restarted = true;
    unawaited(_sample());
  }

  void codecFailed(String error) {
    if (!_active) return;
    outputChanged();
    _pendingError = error;
    _startPolling();
    // Startup retains the existing 40/90 second open deadline. Later failures
    // get a bounded recovery window; repeated errors cannot extend it forever.
    if (_opening?.isCompleted == true) {
      _deadline ??= Timer(recoveryTimeout, () {
        if (!_active || _pendingError == null) return;
        final message = '视频解码恢复超时：$_pendingError';
        cancel();
        onFailure(message);
      });
    }
  }

  void _startPolling() {
    _poll ??= Timer.periodic(sampleInterval, (_) => unawaited(_sample()));
  }

  Future<void> _sample() async {
    if (!_active || !_restarted || _busy || _poll == null) return;
    _busy = true;
    final epoch = _epoch;
    try {
      final state = await readOutput();
      if (!_active || epoch != _epoch || !state.ready) return;
      _poll?.cancel();
      _poll = null;
      _deadline?.cancel();
      _deadline = null;
      if (_opening?.isCompleted == false) _opening!.complete();
      if (_pendingError != null) {
        _pendingError = null;
        onRecovered(state);
      }
    } catch (_) {
      // Unavailable properties are not evidence of success. The startup or
      // recovery deadline and terminal native events remain authoritative.
    } finally {
      _busy = false;
    }
  }

  void cancel() {
    _active = false;
    outputChanged();
    _poll?.cancel();
    _poll = null;
    _deadline?.cancel();
    _deadline = null;
    _pendingError = null;
    if (_opening?.isCompleted == false) {
      _opening!.completeError(StateError('视频输出等待已取消'));
    }
  }
}
