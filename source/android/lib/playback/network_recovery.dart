import 'dart:async';

abstract class NetworkRecoveryBackend {
  Future<void> recoverNetwork(bool Function() current);
}

/// A short event-triggered window, not a permanent playback polling timer.
class NetworkPlaybackRecovery {
  NetworkPlaybackRecovery({
    required this.eligible,
    required this.recover,
    required this.onError,
    this.tick = const Duration(seconds: 1),
  });
  final bool Function() eligible;
  final Future<void> Function(bool Function()) recover;
  final void Function(Object) onError;
  final Duration tick;
  Timer? _timer;
  int _generation = 0, _attempts = 0;
  bool _closed = false, _busy = false;
  void cancel() {
    _generation++;
    _timer?.cancel();
  }

  void changed(bool online) {
    final generation = ++_generation;
    _timer?.cancel();
    if (!online || _closed || _attempts >= 3) return;
    var ticks = 0, stalled = 0;
    _timer = Timer.periodic(tick, (timer) async {
      ticks++;
      if (_closed || generation != _generation || ticks > 20) {
        timer.cancel();
        return;
      }
      if (_busy || !eligible()) {
        stalled = 0;
        return;
      }
      if (++stalled < 3) return;
      timer.cancel();
      _attempts++;
      _busy = true;
      bool current() => !_closed && generation == _generation && eligible();
      try {
        await recover(current);
      } catch (error) {
        if (!_closed && generation == _generation) onError(error);
      } finally {
        _busy = false;
      }
    });
  }

  void close() {
    _closed = true;
    _generation++;
    _timer?.cancel();
  }
}

class NetworkSeekRestoreFailure implements Exception {}

/// Force a same-media native range reopen, restoring the temporary cache option
/// after a real seek/restart. No loadfile, entry resolution, play or speed change.
Future<void> freshNetworkSeek({
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required Future<void> Function() seek,
  required bool Function() restarted,
  required bool Function() active,
  Duration timeout = const Duration(seconds: 10),
}) async {
  const key = 'demuxer-seekable-cache';
  Future<String> get() => read(key).timeout(const Duration(milliseconds: 600));
  Future<void> set(String value) =>
      write(key, value).timeout(const Duration(seconds: 2));
  final previous = await get();
  if (!const {'auto', 'yes', 'no'}.contains(previous)) {
    throw StateError('缓存状态未知');
  }
  if (!active()) return;
  try {
    await set('no');
    if (await get() != 'no') throw StateError('无法刷新网络读取');
    if (!active()) return;
    await seek();
    final clock = Stopwatch()..start();
    while (active() && clock.elapsed < timeout) {
      if (restarted() &&
          await read('seeking').timeout(const Duration(milliseconds: 600)) ==
              'no') {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (active()) throw StateError('网络切换后读取尚未恢复，请重试');
  } finally {
    try {
      await set(previous);
      if (await get() != previous) throw StateError('restore');
    } catch (_) {
      throw NetworkSeekRestoreFailure();
    }
  }
}
