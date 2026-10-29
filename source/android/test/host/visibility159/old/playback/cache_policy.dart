import 'dart:math' as math;

int playbackAheadSeconds(double speed) => speed > 2
    ? 1200
    : speed > 1
    ? 600
    : 60;

/// Ordinary files keep one minute of wall-clock supply, following current rate.
int streamAheadSeconds(double speed) => (60 * speed).ceil().clamp(60, 180);

/// CPU decoded pictures have a separate bound from compressed packet caching.
/// Keep the existing memory tiers; large pictures may allow only one frame.
int playbackCopyQueueBytes(int packetBytes) => packetBytes >= 128 * 1024 * 1024
    ? 160 * 1024 * 1024
    : packetBytes.clamp(16 * 1024 * 1024, 64 * 1024 * 1024);

/// Seconds on the film's timeline, independent of the resume/start gate.
/// The largest requested window lives until this media closes, including holds.
class PlaybackReadAhead {
  int seconds = 60;
  void speed(double value, {bool retainPeak = true}) {
    seconds = retainPeak
        ? math.max(seconds, playbackAheadSeconds(value))
        : streamAheadSeconds(value);
  }

  int bytes({required int total, required Duration duration}) {
    if (duration <= Duration.zero) return 0;
    // A byte window is an estimate for variable-bitrate files. MPV still owns
    // timestamp-aware demuxing; never describe this estimate as verified time.
    return math.min(
      total,
      (total * seconds * 1000 / duration.inMilliseconds * 1.15).ceil(),
    );
  }
}

const playbackCacheChoices = <int, String>{
  0: '不缓存',
  2: '2 GB',
  5: '5 GB',
  10: '10 GB',
  20: '20 GB',
  50: '50 GB',
  -1: '不限制',
};
const playbackGiB = 1024 * 1024 * 1024;
