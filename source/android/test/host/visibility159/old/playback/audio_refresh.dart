import 'dart:async';

class AudioRefreshRestoreFailure implements Exception {
  const AudioRefreshRestoreFailure();
  @override
  String toString() => '音轨刷新参数未能恢复，已保留观看进度';
}

/// Called inside the existing command queue. A track switch can leave a
/// partially populated packet range; a cached seek is not a fresh demux seek.
/// Keep the exact display target, but decode from at least one second before
/// it. Restore both options before releasing the queue, even on cancellation.
Future<void> freshAudioSeek({
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required Future<void> Function() seek,
  required bool Function() restarted,
  required bool Function() active,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final previous = <String, String>{};
  const cache = 'demuxer-seekable-cache', offset = 'hr-seek-demuxer-offset';
  Future<String> get(String key) =>
      read(key).timeout(const Duration(milliseconds: 600));
  Future<void> set(String key, String value) async {
    await write(key, value).timeout(const Duration(seconds: 2));
    if (await get(key) != value) {
      throw StateError('Audio seek option unconfirmed');
    }
  }

  try {
    final cached = await get(cache), lead = await get(offset);
    final seconds = double.tryParse(lead);
    if (!const {'auto', 'yes', 'no'}.contains(cached) ||
        seconds == null ||
        !seconds.isFinite ||
        seconds < 0) {
      throw StateError('Audio seek options unavailable');
    }
    if (!active()) return;
    // Register before writes: even a rejected/readback-failed write is undone.
    previous[cache] = cached;
    await set(cache, 'no');
    if (!active()) return;
    previous[offset] = lead;
    await write(
      offset,
      seconds < 1 ? '1' : lead,
    ).timeout(const Duration(seconds: 2));
    if ((double.tryParse(await get(offset)) ?? -1) !=
        (seconds < 1 ? 1 : seconds)) {
      throw StateError('Audio preroll unconfirmed');
    }
    if (!active()) return;
    await seek();
    final clock = Stopwatch()..start();
    while (active() && clock.elapsed < timeout) {
      // The command acknowledgement can precede execution. Old seeking=no or
      // an old audio format cannot confirm this seek, especially while paused.
      if (restarted() && await get('seeking') == 'no') return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (active()) throw StateError('Audio refresh did not restart');
  } finally {
    var failed = false;
    for (final entry in previous.entries.toList().reversed) {
      try {
        await write(entry.key, entry.value).timeout(const Duration(seconds: 2));
        if (await get(entry.key) != entry.value) failed = true;
      } catch (_) {
        failed = true;
      }
    }
    if (failed) throw const AudioRefreshRestoreFailure();
  }
}
