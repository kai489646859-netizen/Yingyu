/// Apply the existing initial media-time cushion to ordinary network files.
/// No extra timer, request, larger cache target or playback command is added.
class InitialStreamBuffer {
  String? _previous;

  Future<bool> prepare({
    required bool enabled,
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    const key = 'cache-pause-initial';
    final previous = _previous;
    if (previous != null) {
      await write(key, previous);
      if (await read(key) != previous) {
        throw StateError('初始缓冲参数未能恢复');
      }
      _previous = null;
    }
    if (!enabled) return false;
    final original = await read(key);
    if (original == 'yes') return true;
    if (original != 'no') return false;
    try {
      await write(key, 'yes');
      if (await read(key) != 'yes') {
        throw StateError('初始缓冲参数未确认');
      }
      _previous = original;
      return true;
    } catch (_) {
      await write(key, original);
      if (await read(key) != original) {
        throw StateError('初始缓冲参数未能恢复');
      }
      return false;
    }
  }
}
