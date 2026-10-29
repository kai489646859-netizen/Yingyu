import 'disc_buffering.dart';

double discBufferTier(double speed) => speed <= 1
    ? 1
    : speed <= 2
    ? 2
    : 3;

/// Cache tiers do not alter the selected playback rate. Opening and explicit
/// seeks always start with the original 1x budget, even at a selected 3x rate.
class DiscBufferPlan {
  DiscBufferPlan({
    required double speed,
    required this.fast,
    required int baseBytes,
    required int memoryMiB,
  }) : tier = fast ? 1 : discBufferTier(speed),
       playbackTier = fast ? 1 : discBufferTier(speed),
       bytes = fast
           ? baseBytes
           : discForwardBufferBytes(
               baseBytes,
               discBufferTier(speed),
               memoryMiB,
             );

  final bool fast;
  final double tier, playbackTier;
  final int bytes;
  DiscBufferPlan._({
    required this.fast,
    required this.tier,
    required this.playbackTier,
    required this.bytes,
  });

  /// Retain already configured prefetch bytes/rate, but lower the resume gate
  /// immediately with actual playback speed. A retained 3x cache must never
  /// impose its 24-media-second restart wait on restored 1x playback.
  DiscBufferPlan withPlaybackSpeed(double speed) => DiscBufferPlan._(
    fast: fast,
    tier: tier,
    playbackTier: fast ? 1 : discBufferTier(speed),
    bytes: bytes,
  );

  Map<String, String> get options => {
    ...discBufferOptions(tier, forwardBytes: bytes),
    'cache-pause-wait': discBufferOptions(playbackTier)['cache-pause-wait']!,
  };
}

/// Neither a size notification nor a completed seek command proves that the
/// new frame is available. Require restart + VO frame + settled cache/seek.
class DiscBufferPhase {
  int epoch = 0;
  bool fast = true, armed = false, restarted = false;
  bool promotionFailed = false;

  void begin() {
    epoch++;
    fast = true;
    armed = restarted = promotionFailed = false;
  }

  void arm() => armed = true;
  void restart() {
    if (armed) restarted = true;
  }

  bool canPromote({
    required int sampleEpoch,
    required bool outputReady,
    required bool buffering,
    required bool cachePaused,
    required bool seeking,
  }) =>
      fast &&
      armed &&
      restarted &&
      !promotionFailed &&
      sampleEpoch == epoch &&
      outputReady &&
      !buffering &&
      !cachePaused &&
      !seeking;

  void complete(int sampleEpoch) {
    if (sampleEpoch == epoch) fast = false;
  }

  void cancel() {
    epoch++;
    armed = false;
  }
}
