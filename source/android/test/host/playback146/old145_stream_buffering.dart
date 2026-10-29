import 'package:yingyu/playback/cache_policy.dart';
import 'package:yingyu/playback/disc_buffering.dart';

class StreamBufferSnapshot {
  const StreamBufferSnapshot._(
    this.ahead,
    this.bytes,
    this.gate,
    this.starved,
    this.requestedAhead,
  );
  final int ahead, bytes;
  final String? gate;
  final bool starved;
  final int requestedAhead;
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
  bool _starved = false;

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
  StreamBufferSnapshot get snapshot => StreamBufferSnapshot._(
    _appliedAhead,
    _appliedBytes,
    applied,
    _starved,
    aheadSeconds,
  );

  void beginFast() => _starved = false;

  Future<void> markStarved(double speed, {required bool fast}) async {
    if (_starved) return;
    await _configure(speed, fast: fast, starved: true);
  }

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
    _starved = next.starved;
    aheadSeconds = next.requestedAhead;
  }

  Future<void> configure(double speed, {required bool fast}) async {
    await _configure(speed, fast: fast, starved: _starved);
  }

  Future<void> _configure(
    double speed, {
    required bool fast,
    required bool starved,
  }) async {
    final requested = streamAheadSeconds(speed);
    // Pre-reading and resuming are different controls. A larger window never
    // becomes a ten/twenty-minute restart gate, including after a seek.
    final ahead = fast ? 10 : requested;
    final bytes = fast
        ? baseBytes
        : discForwardBufferBytes(
            baseBytes,
            speed,
            memoryMiB,
            previousBytes: baseBytes,
          );
    final ordinary = double.parse(target(speed, fast: fast));
    final cushion = starved && speed * 2 > ordinary ? speed * 2 : ordinary;
    await _apply(
      StreamBufferSnapshot._(
        ahead,
        bytes,
        cushion.toStringAsFixed(2),
        starved,
        requested,
      ),
    );
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
