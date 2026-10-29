import 'cache_policy.dart';
import 'disc_buffering.dart';

class StreamBufferSnapshot {
  const StreamBufferSnapshot._(
    this.ahead,
    this.bytes,
    this.gate,
    this.starved,
    this.requestedAhead,
    this.recoveryLevel,
  );
  final int ahead, bytes;
  final String? gate;
  final bool starved;
  final int requestedAhead;
  final int recoveryLevel;
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
  int _recoveryLevel = 0, _notificationEpoch = 0;
  bool _starvationActive = false;

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
    _recoveryLevel,
  );

  void beginFast({bool preserveRecovery = false}) {
    endStarvation();
    if (!preserveRecovery) {
      _starved = false;
      _recoveryLevel = 0;
    }
  }

  void endStarvation() {
    _starvationActive = false;
    _notificationEpoch++;
  }

  Future<void> markStarved(double speed, {required bool fast}) async {
    if (_starvationActive) return;
    final epoch = _notificationEpoch;
    _starvationActive = true;
    try {
      await _configure(
        speed,
        fast: fast,
        starved: true,
        recoveryLevel: fast
            ? _recoveryLevel.clamp(1, 2)
            : (_recoveryLevel + 1).clamp(1, 2),
      );
    } catch (_) {
      if (epoch == _notificationEpoch) _starvationActive = false;
      rethrow;
    }
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
    _recoveryLevel = next.recoveryLevel;
  }

  Future<void> configure(double speed, {required bool fast}) async {
    await _configure(speed, fast: fast, starved: _starved);
  }

  Future<void> _configure(
    double speed, {
    required bool fast,
    required bool starved,
    int? recoveryLevel,
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
    final level = recoveryLevel ?? _recoveryLevel;
    final recovery = speed * (level >= 2 ? 4 : 2);
    final cushion = starved && recovery > ordinary ? recovery : ordinary;
    await _apply(
      StreamBufferSnapshot._(
        ahead,
        bytes,
        cushion.toStringAsFixed(2),
        starved,
        requested,
        level,
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
