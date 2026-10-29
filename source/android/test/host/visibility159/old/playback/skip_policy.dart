import '../core/personal_library.dart';

enum SkipPart { intro, credits }

class SkipTarget {
  const SkipTarget(this.part, this.position);
  final SkipPart part;
  final Duration position;
}

/// A visible opportunity to keep watching before an automatic skip. The UI
/// pauses its one-second timer while playback is paused or buffering.
class SkipCountdown {
  SkipCountdown(this.target);
  final SkipTarget target;
  int remaining = 3;

  bool tick({required bool allowed}) {
    if (!allowed || remaining == 0) return false;
    remaining--;
    return remaining == 0;
  }
}

/// One automatic attempt per part and playback session. Neither a failed seek
/// nor dragging back re-arms it. Manual buttons remain available in the range.
class SkipPolicy {
  final Set<SkipPart> _attempted = {};

  void consume(SkipPart part) => _attempted.add(part);

  void suppressCurrent(SkipRule? rule, Duration position, Duration duration) {
    if (rule?.introContains(position, duration) == true) {
      consume(SkipPart.intro);
    }
    if (rule?.creditsContains(position, duration) == true) {
      consume(SkipPart.credits);
    }
  }

  SkipTarget? automatic({
    required SkipRule? rule,
    required Duration position,
    required Duration duration,
    required bool allowed,
    required bool seeking,
  }) {
    // Seeking is a user intent boundary even when its command is still pending.
    if (seeking) suppressCurrent(rule, position, duration);
    if (!allowed || seeking || rule == null) return null;
    if (rule.autoIntro &&
        !_attempted.contains(SkipPart.intro) &&
        rule.introContains(position, duration)) {
      consume(SkipPart.intro);
      return SkipTarget(SkipPart.intro, rule.intro!.end);
    }
    if (rule.autoCredits &&
        !_attempted.contains(SkipPart.credits) &&
        rule.creditsContains(position, duration)) {
      consume(SkipPart.credits);
      return SkipTarget(SkipPart.credits, duration);
    }
    return null;
  }
}
