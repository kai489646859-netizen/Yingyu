import 'cache_policy.dart';
import 'disc_buffering.dart';

class StreamBufferSnapshot {
  const StreamBufferSnapshot._(this.ahead, this.bytes, this.gate);
  final int ahead, bytes;
  final String? gate;
}

/// Ordinary files, HDR and Dolby share a bounded packet budget and ahead time.
/// In the pinned MPV, cache-pause-wait is expressed in media seconds.
/// It does not pause an already running stream merely to reach this target.
class StreamBuffering {
  StreamBuffering({
    required this.write,
    required this.onRestoreFailure,
    this.baseBytes = 64 * 1024 * 1024,
    this.memoryMiB = 64,
  });
  final Future<void> Function(String, String) write;
  final void Function() onRestoreFailure;
  final int baseBytes, memoryMiB;
  String? applied;

  static String target(double speed, {required bool fast}) =>
      (fast || speed <= 1
              ? 1.0
              : speed <= 2
              ? speed * 4
              : speed * 8)
          .toStringAsFixed(2);

  int aheadSeconds = 60;
  int _appliedAhead = 3600000;
  late int _appliedBytes = baseBytes;
  late int _retainedBytes = baseBytes;
  StreamBufferSnapshot get snapshot =>
      StreamBufferSnapshot._(_appliedAhead, _appliedBytes, applied);

  Future<void> restoreSnapshot(StreamBufferSnapshot value) => _apply(value);

  Future<void> _apply(StreamBufferSnapshot next) async {
    final previous = snapshot;
    Map<String, String> options(StreamBufferSnapshot value) => {
      'cache-secs': '${value.ahead}',
      'demuxer-max-bytes': '${value.bytes}',
      'cache-pause-wait': value.gate ?? '1.00',
    };
    final before = options(previous), after = options(next);
    final attempted = <String>[];
    try {
      for (final entry in after.entries) {
        if (before[entry.key] == entry.value &&
            !(entry.key == 'cache-pause-wait' && applied == null)) {
          continue;
        }
        // A native setter may mutate before reporting a failure.
        attempted.add(entry.key);
        await write(entry.key, entry.value);
      }
    } catch (_) {
      var failed = false;
      for (final key in attempted.reversed) {
        try {
          await write(key, before[key]!);
        } catch (_) {
          failed = true;
        }
      }
      if (failed) onRestoreFailure();
      rethrow;
    }
    _appliedAhead = next.ahead;
    _appliedBytes = next.bytes;
    applied = next.gate;
  }

  Future<void> configure(double speed, {required bool fast}) async {
    final requested = playbackAheadSeconds(speed);
    if (requested > aheadSeconds) aheadSeconds = requested;
    // Pre-reading and resuming are different controls. A larger window never
    // becomes a ten/twenty-minute restart gate, including after a seek.
    final ahead = fast ? 10 : aheadSeconds;
    final bytes = fast
        ? baseBytes
        : discForwardBufferBytes(
            baseBytes,
            speed,
            memoryMiB,
            previousBytes: _retainedBytes,
          );
    await _apply(
      StreamBufferSnapshot._(ahead, bytes, target(speed, fast: fast)),
    );
    if (!fast) _retainedBytes = bytes;
  }

  Future<void> restore(String? target) async {
    if (target == null || target == applied) return;
    final previous = applied ?? '1.00';
    try {
      await write('cache-pause-wait', target);
      applied = target;
    } catch (_) {
      try {
        await write('cache-pause-wait', previous);
      } catch (_) {
        onRestoreFailure();
      }
      rethrow;
    }
  }

  String get description =>
      '普通原文件；预读目标=$aheadSeconds 秒媒体时间；'
      '前向包缓存上限=${_appliedBytes ~/ (1024 * 1024)} MiB；'
      '恢复播放目标=${applied ?? "尚未配置"} 秒媒体时间';
}
