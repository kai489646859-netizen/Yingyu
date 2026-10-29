import 'dart:async';

/// Let an initial native track refresh settle while the existing opening pause
/// still owns playback. This reads only current MPV properties, never media.
/// A deadline or unknown value leaves the normal buffering rules in charge.
Future<String> settleOpeningBuffer({
  required Future<String> Function(String) read,
  required bool Function() active,
  Duration timeout = const Duration(seconds: 5),
  Future<void> Function(Duration)? wait,
  Duration Function()? elapsed,
}) async {
  final clock = Stopwatch()..start();
  final now = elapsed ?? (() => clock.elapsed);
  final delay = wait ?? ((duration) => Future<void>.delayed(duration));
  Duration? stableSince;
  while (active() && now() < timeout) {
    final left = timeout - now();
    if (left <= Duration.zero) break;
    final List<String> values;
    try {
      values =
          await Future.wait([
            for (final key in const [
              'seeking',
              'paused-for-cache',
              'demuxer-cache-duration',
              'demuxer-cache-idle',
              'eof-reached',
              'cache-pause-wait',
            ])
              read(key),
          ]).timeout(
            left < const Duration(milliseconds: 500)
                ? left
                : const Duration(milliseconds: 500),
          );
    } catch (_) {
      return active() ? '缓存状态未知，沿用内核缓冲条件' : '已取消';
    }
    if (!active()) return '已取消';
    final seconds = double.tryParse(values[2]);
    final known = const {'yes', 'no'};
    if (!known.contains(values[0]) ||
        !known.contains(values[1]) ||
        !known.contains(values[3]) ||
        !known.contains(values[4])) {
      return '缓存状态未知，沿用内核缓冲条件';
    }
    final resume = double.tryParse(values[5]);
    // Match the configured native resume gate instead of imposing a second
    // fixed four-second gate after an already verified output frame.
    final target =
        resume != null && resume.isFinite && resume > 0 && resume <= 120
        ? resume
        : 4.0;
    final enough =
        values[3] == 'yes' ||
        values[4] == 'yes' ||
        seconds != null &&
            seconds.isFinite &&
            seconds >= target &&
            seconds <= 120;
    if (values[0] == 'no' && values[1] == 'no' && enough) {
      stableSince ??= now();
      // A sid change can invalidate its old cache a few hundred ms after the
      // property reply. One immediate read would accept that stale cache.
      if (now() - stableSince >= const Duration(milliseconds: 500)) {
        return '初始轨道已稳定，缓存衔接完成';
      }
    } else {
      stableSince = null;
    }
    final remaining = timeout - now();
    if (remaining <= Duration.zero) break;
    await delay(
      remaining < const Duration(milliseconds: 50)
          ? remaining
          : const Duration(milliseconds: 50),
    );
  }
  return active() ? '有界等待结束，沿用内核缓冲条件' : '已取消';
}
