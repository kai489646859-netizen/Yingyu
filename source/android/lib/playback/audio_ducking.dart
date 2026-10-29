abstract class PlaybackDuckingBackend {
  Future<void> setAudioDucked(bool value);
}

/// Change only this player's gain; system volume and pause intent are untouched.
class PlaybackDucking {
  PlaybackDucking({required this.read, required this.write});
  final double Function() read;
  final Future<void> Function(double) write;
  Future<void> _pending = Future.value();
  double? _original;
  bool _closed = false;

  Future<void> set(bool duck) {
    final job = _pending.then((_) async {
      if (_closed) return;
      if (duck) {
        if (_original != null) return;
        final volume = read();
        if (!volume.isFinite || volume < 0) {
          throw StateError('播放器音量状态不可用');
        }
        await write(volume * .2);
        _original = volume;
      } else if (_original != null) {
        await write(_original!);
        _original = null;
      }
    });
    // Keep later gain/cleanup actionable after one failed operation.
    _pending = job.catchError((Object _) {});
    return job;
  }

  Future<void> close() {
    _closed = true;
    return _pending;
  }
}
