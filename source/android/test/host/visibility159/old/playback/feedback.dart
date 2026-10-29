import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../ui/style.dart';

/// Local gesture HUD. Its animation has no dependency on the media clock.
class PlaybackLevelFeedback extends StatelessWidget {
  const PlaybackLevelFeedback({
    super.key,
    required this.brightness,
    required this.level,
  });
  final bool brightness;
  final double level;
  @override
  Widget build(BuildContext context) => Semantics(
    label: brightness ? '屏幕亮度' : '音量',
    value: '${(level.clamp(0, 1) * 100).round()}',
    child: Container(
      key: ValueKey(
        brightness ? 'brightness-level-feedback' : 'volume-level-feedback',
      ),
      width: 274,
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xE62C2C31), Color(0xD91A1A1F)],
        ),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.white12),
      ),
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: level.clamp(0, 1)),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        builder: (context, value, _) {
          final icon = value <= .001
              ? Icons.volume_off_outlined
              : value < .5
              ? Icons.volume_down_outlined
              : Icons.volume_up_outlined;
          return Row(
            children: [
              SizedBox(
                width: 28,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: brightness
                        ? child
                        : ScaleTransition(
                            scale: animation.drive(Tween(begin: .8, end: 1.0)),
                            child: child,
                          ),
                  ),
                  child: brightness
                      ? BrightnessSun(
                          key: ValueKey(BrightnessSun.fillForLevel(value)),
                          level: value,
                        )
                      : Icon(
                          icon,
                          key: ValueKey(icon),
                          size: 24,
                          color: accentColor(context),
                        ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 5,
                    child: Stack(
                      children: [
                        const Positioned.fill(
                          child: ColoredBox(color: Colors.white12),
                        ),
                        FractionallySizedBox(
                          widthFactor: value,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  accentColor(context),
                                  Color.lerp(
                                    accentColor(context),
                                    Colors.white,
                                    .22,
                                  )!,
                                ],
                              ),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// Three fixed discs share the same separate rays: empty, half, and full.
class BrightnessSun extends StatelessWidget {
  const BrightnessSun({
    super.key = const ValueKey('brightness-sun'),
    required this.level,
  });
  final double level;
  static double fillForLevel(double level) => level < 1 / 3
      ? 0
      : level < 2 / 3
      ? .5
      : 1;
  @override
  Widget build(BuildContext context) {
    Widget sun(IconData icon) =>
        Icon(icon, size: 24, color: accentColor(context));
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        children: [
          sun(Icons.wb_sunny_outlined),
          ClipRect(
            key: const Key('brightness-sun-fill'),
            clipper: _SunFillClipper(fillForLevel(level)),
            child: sun(Icons.wb_sunny),
          ),
        ],
      ),
    );
  }
}

class _SunFillClipper extends CustomClipper<Rect> {
  const _SunFillClipper(this.fill);
  final double fill;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(
    size.width * .25,
    size.height * .25,
    size.width * (.25 + .5 * fill),
    size.height * .75,
  );
  @override
  bool shouldReclip(_SunFillClipper oldClipper) => fill != oldClipper.fill;
}

/// The held-speed anchor follows the user's marked upper-center position.
/// Encoded letterbox bars are part of the texture, so texture bounds alone
/// cannot locate the visible picture. Other gesture positions stay unchanged.
class PlaybackFeedback extends StatelessWidget {
  const PlaybackFeedback({
    super.key,
    required this.text,
    required this.boosted,
    required this.fit,
    this.aspectRatio,
  });
  final String text;
  final bool boosted;
  final BoxFit fit;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final safe = MediaQuery.viewPaddingOf(context);
      final pill = Container(
        key: const Key('playback-gesture-feedback'),
        padding: EdgeInsets.symmetric(
          horizontal: boosted ? 18 : 24,
          vertical: boosted ? 8 : 14,
        ),
        decoration: BoxDecoration(
          color: const Color(0x663C3C43),
          border: Border.all(color: const Color(0x33FFFFFF)),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: accentColor(context),
            fontSize: 15,
            fontWeight: FontWeight.w600,
            height: 1.15,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 2)],
          ),
        ),
      );
      if (!boosted) {
        return Align(alignment: const Alignment(0, -.5), child: pill);
      }
      final size = bounds.biggest;
      final height = MediaQuery.textScalerOf(context).scale(15) * 1.15 + 18;
      final top = math.max(safe.top + 8, size.height * .10 - height / 2);
      return Stack(
        children: [
          Positioned(
            top: math.min(
              top,
              math.max(safe.top, size.height - safe.bottom - height),
            ),
            left: math.max(safe.left, safe.right) + 12,
            right: math.max(safe.left, safe.right) + 12,
            child: Align(alignment: Alignment.topCenter, child: pill),
          ),
        ],
      );
    },
  );
}

/// Local display only. Its lifetime follows player state, never the controls.
class PlaybackLoadingFeedback extends StatelessWidget {
  const PlaybackLoadingFeedback({super.key, required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Center(
      child: Semantics(
        liveRegion: true,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 300),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(
                  strokeWidth: 3.5,
                  color: accentColor(context),
                  backgroundColor: Colors.white24,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  height: 1.4,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Confirmed EOF only. Buttons call the existing replay and episode paths.
class PlaybackEndedFeedback extends StatelessWidget {
  const PlaybackEndedFeedback({
    super.key,
    required this.episode,
    required this.description,
    this.onReplay,
    this.onNext,
  });
  final bool episode;
  final String description;
  final VoidCallback? onReplay, onNext;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Semantics(
          liveRegion: true,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 340),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xF21C1C1E),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.check_circle_outline,
                  color: accentColor(context),
                  size: 34,
                ),
                const SizedBox(height: 12),
                Text(
                  episode ? '本集已播放完' : '影片已播放完',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    description,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                ],
                if (onReplay != null || onNext != null) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    children: [
                      if (onReplay != null)
                        TextButton(
                          key: const Key('playback-end-replay'),
                          onPressed: onReplay,
                          child: const Text('重新播放'),
                        ),
                      if (onNext != null)
                        FilledButton(
                          key: const Key('playback-end-next'),
                          onPressed: onNext,
                          child: const Text('下一集'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// One continuous eight-second presentation per open. Initial buffering delays
/// it; later buffering cannot hide and replay the same notice. A menu or exit
/// still dismisses it permanently.
class SourceFormatNotice extends StatefulWidget {
  const SourceFormatNotice({
    super.key,
    required this.text,
    required this.onDone,
    this.visible = true,
    this.suspended = false,
    this.icon = Icons.high_quality_outlined,
  });
  final String text;
  final VoidCallback onDone;
  final bool visible;
  final bool suspended;
  final IconData icon;
  @override
  State<SourceFormatNotice> createState() => _SourceFormatNoticeState();
}

class _SourceFormatNoticeState extends State<SourceFormatNotice> {
  Timer? timer;
  bool finished = false;
  bool presented = false;
  bool get waitingForFirstPresentation => widget.suspended && !presented;
  Duration remaining = const Duration(seconds: 8);
  Duration? shownAt;
  @override
  void initState() {
    super.initState();
    updatePresentation();
  }

  @override
  void didUpdateWidget(covariant SourceFormatNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    updatePresentation();
  }

  void updatePresentation() {
    if (finished) return;
    // Visibility changes arrive in a frame. Its monotonic timestamp also
    // makes the visible-time budget independent of wall-clock corrections.
    final now = WidgetsBinding.instance.currentSystemFrameTimeStamp;
    if (!widget.visible || waitingForFirstPresentation) {
      if (shownAt != null) remaining -= now - shownAt!;
      shownAt = null;
      timer?.cancel();
      timer = null;
    }
    if (widget.visible &&
        !waitingForFirstPresentation &&
        remaining > Duration.zero) {
      presented = true;
      shownAt ??= now;
      timer ??= Timer(remaining, () {
        if (!mounted || finished) return;
        setState(() => finished = true);
        widget.onDone();
      });
    } else if ((!widget.visible && presented) || remaining <= Duration.zero) {
      finished = true;
      timer?.cancel();
      // The visibility change arrives during the parent's build. Complete
      // after this frame, and never let a disposed open clear a newer notice.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onDone();
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      !widget.visible || waitingForFirstPresentation || finished
      ? const SizedBox.shrink()
      : Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xEE1C1C1E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accentColor(context).withValues(alpha: .7),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 20, color: accentColor(context)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.text,
                  key: const Key('source-notice'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        );
}
