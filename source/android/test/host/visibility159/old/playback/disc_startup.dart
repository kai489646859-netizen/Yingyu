import 'dart:async';

/// A bounded cold-start cushion before the first play command. Real full-cache
/// or EOF state wins; unknown properties never turn into fake buffered seconds.
Future<String> waitForDiscCushion({
  required Future<String> Function(String) read,
  required bool Function() active,
  Duration timeout = const Duration(seconds: 3),
}) async {
  final clock = Stopwatch()..start();
  while (active() && clock.elapsed < timeout) {
    try {
      final left = timeout - clock.elapsed;
      final values = await Future.wait([
        read('demuxer-cache-duration'),
        read('demuxer-cache-idle'),
        read('eof-reached'),
        read('cache-pause-wait'),
      ]).timeout(left);
      if (!active()) return '已取消';
      final seconds = double.tryParse(values[0]);
      if (values[1] == 'yes' || values[2] == 'yes') return '缓存已满或到达文件尾';
      final resume = double.tryParse(values[3]);
      // The frame is already verified. Do not impose a second, higher gate
      // than MPV's current recovery threshold (normally two media seconds).
      final target =
          resume != null && resume.isFinite && resume > 0 && resume <= 120
          ? resume
          : 4.0;
      if (seconds != null &&
          seconds.isFinite &&
          seconds >= target &&
          seconds <= 120) {
        return '已达到内核恢复门槛（$target秒媒体时间）';
      }
    } catch (_) {
      return active() ? '缓存暂不可确认，沿用内核恢复条件' : '已取消';
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return active() ? '有界等待结束，沿用内核恢复条件' : '已取消';
}

/// The validated VideoLAN playlist supplies every EDL segment's start/length.
/// FFmpeg's separate MPEG-TS tail scan estimates a duration we already have.
/// Keep stream discovery, timestamp seeking and all ordinary media unchanged.
class DiscStartupSetup {
  Future<String>? _job;

  Future<String> prepare({
    required bool hasPlaylistTimeline,
    required Future<String> Function(String) read,
    required Future<void> Function(List<String>) command,
  }) {
    if (!hasPlaylistTimeline) return Future.value('沿用普通媒体探测');
    return _job ??= _prepare(read, command);
  }

  Future<String> _prepare(
    Future<String> Function(String) read,
    Future<void> Function(List<String>) command,
  ) async {
    const option = 'demuxer-lavf-o';
    const key = 'skip_estimate_duration_from_pts';
    String? previous;
    var attempted = false;
    try {
      previous = await read('options/$option');
      // media_kit already configures this map, including its protocol list.
      // Append only our new key; never replace or reparse the existing values.
      if (previous.contains(key)) return '已有原盘时长估算设置，保留原值';
      attempted = true;
      await command(['change-list', option, 'append', '$key=1']);
      final expected = previous.isEmpty ? '$key=1' : '$previous,$key=1';
      if (await read('options/$option') != expected) {
        throw StateError('Duration option was not confirmed');
      }
      return '原盘使用播放列表时长，跳过额外片尾时长估算；轨道探测与定位保留';
    } catch (_) {
      if (attempted && previous != null) {
        await command(['change-list', option, 'remove', key]);
        if (await read('options/$option') != previous) {
          throw StateError('原盘探测配置未能恢复');
        }
      }
      return '原盘时长优化未启用，保留原配置';
    }
  }
}

/// Keep nearby MPEG-TS probes inside MPV's byte buffer, as the PC disc bridge
/// does. This is independent of demuxer packet prefetch and does not shorten
/// track discovery. Restore the original value before opening ordinary media.
class DiscProbeSetup {
  String? _original;
  Future<void> _tail = Future.value();
  Future<String?> prepare({
    required bool disc,
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) {
    final result = _tail.then((_) => _prepare(disc, read, write));
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String?> _prepare(
    bool disc,
    Future<String> Function(String) read,
    Future<void> Function(String, String) write,
  ) async {
    const key = 'stream-buffer-size';
    if (!disc) {
      if (_original == null) return null;
      await write(key, _original!);
      if (await read('options/$key') != _original) {
        throw StateError('普通媒体字节缓冲配置未能恢复');
      }
      _original = null;
      return null;
    }
    if (_original != null) return null;
    final previous = await read('options/$key');
    final bytes = int.tryParse(previous);
    if (bytes == null || bytes < 0) return '原盘探测字节缓冲值未知，保留原值';
    if (bytes >= 4 * 1024 * 1024) return '原盘保留已有较大的探测字节缓冲';
    try {
      await write(key, '4194304');
      if (await read('options/$key') != '4194304') {
        throw StateError('原盘探测字节缓冲未生效');
      }
      _original = previous;
      return '原盘探测字节缓冲=4 MiB；附近回读优先复用；完整轨道探测与准确定位保留';
    } catch (_) {
      await write(key, previous);
      if (await read('options/$key') != previous) {
        throw StateError('原盘探测字节缓冲配置未能恢复');
      }
      return '原盘探测字节缓冲未启用，已恢复原配置';
    }
  }
}
