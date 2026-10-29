import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'style.dart';
import 'poster_service.dart';

class AlphabetRail extends StatefulWidget {
  const AlphabetRail({
    super.key,
    required this.available,
    required this.onSelect,
    this.current,
    this.descending = false,
  });
  final Set<String> available;
  final ValueChanged<String> onSelect;
  final String? current;
  final bool descending;
  @override
  State<AlphabetRail> createState() => _AlphabetRailState();
}

class _AlphabetRailState extends State<AlphabetRail>
    with WidgetsBindingObserver {
  static const baseLetters = '#ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  String get letters =>
      widget.descending ? baseLetters.split('').reversed.join() : baseLetters;
  String? selected, pressed;
  String? pending, dispatched;
  bool scheduled = false;
  int? pointer;
  Timer? resumeImages;
  Timer? hapticCooldown;
  void tick({bool initial = false}) {
    if (hapticCooldown != null) return;
    unawaited(
      initial ? HapticFeedback.lightImpact() : HapticFeedback.selectionClick(),
    );
    // Discrete ticks instead of a continuous buzz during a fast scrub.
    hapticCooldown = Timer(
      const Duration(milliseconds: 65),
      () => hapticCooldown = null,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void stopScrubbing() {
    hapticCooldown?.cancel();
    hapticCooldown = null;
    resumeImages?.cancel();
    PosterDemand.pause(this, false);
    pointer = null;
    pending = null;
    pressed = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      stopScrubbing();
      if (mounted) setState(() {});
    }
  }

  @override
  void deactivate() {
    stopScrubbing();
    super.deactivate();
  }

  @override
  void dispose() {
    stopScrubbing();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void select(String value) {
    if (pressed == value) return;
    setState(() {
      if (widget.available.contains(value)) selected = value;
      pressed = value;
    });
    if (!widget.available.contains(value)) return;
    tick();
    pending = value;
    if (scheduled) return;
    scheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      scheduled = false;
      final value = pending;
      pending = null;
      if (!mounted ||
          value == null ||
          !widget.available.contains(value) ||
          dispatched == value) {
        return;
      }
      dispatched = value;
      widget.onSelect(value);
    });
  }

  void release() {
    pointer = null;
    setState(() => pressed = null);
    resumeImages?.cancel();
    // Let the final jump and visibility callbacks settle before admitting HTTP.
    resumeImages = Timer(const Duration(milliseconds: 120), () {
      PosterDemand.pause(this, false);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final height = math.min(bounds.maxHeight, 27 * 22.0);
      final top = (bounds.maxHeight - height) / 2;
      final candidate = pointer != null ? selected : widget.current ?? selected;
      final current = widget.available.contains(candidate)
          ? candidate
          : letters.split('').where(widget.available.contains).firstOrNull;
      final compact = height < 27 * 16;
      final labels = <int>[];
      final currentIndex = current == null ? -1 : letters.indexOf(current);
      double labelTop(int i) =>
          ((i + .5) * height / 27 - 9).clamp(0.0, math.max(0.0, height - 18));
      if (compact && height >= 18) {
        for (final i in [
          if (currentIndex >= 0) currentIndex,
          0,
          26,
          for (var i = 0; i < 27; i++) i,
        ]) {
          if (labels.every(
            (other) => (labelTop(other) - labelTop(i)).abs() >= 18,
          )) {
            labels.add(i);
          }
        }
      }
      void locate(Offset position) =>
          select(letters[(position.dy / (height / 27)).floor().clamp(0, 26)]);
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: top.toDouble()),
          child: SizedBox(
            key: const Key('alphabet-hit-area'),
            width: 44,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (d) {
                    if (pointer != null) return;
                    resumeImages?.cancel();
                    PosterDemand.pause(this, true);
                    tick(initial: true);
                    pointer = d.pointer;
                    dispatched = null;
                    locate(d.localPosition);
                  },
                  onPointerMove: (d) {
                    if (pointer == d.pointer) locate(d.localPosition);
                  },
                  onPointerUp: (d) {
                    if (pointer == d.pointer) release();
                  },
                  onPointerCancel: (d) {
                    if (pointer == d.pointer) release();
                  },
                  child: Column(
                    children: [
                      for (final letter in letters.split(''))
                        Expanded(
                          child: Semantics(
                            label: '拼音 $letter',
                            value: widget.available.contains(letter)
                                ? '有影片'
                                : '无影片',
                            button: true,
                            selected: current == letter,
                            enabled: widget.available.contains(letter),
                            excludeSemantics: true,
                            onTap: widget.available.contains(letter)
                                ? () {
                                    select(letter);
                                    dispatched = null;
                                    release();
                                  }
                                : null,
                            child: letterLabel(
                              context,
                              letter,
                              current,
                              showText: !compact,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (compact)
                  for (final i in labels)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: labelTop(i),
                      height: 18,
                      child: IgnorePointer(
                        child: ExcludeSemantics(
                          child: letterLabel(
                            context,
                            letters[i],
                            current,
                            compact: true,
                          ),
                        ),
                      ),
                    ),
                if (pressed != null)
                  Positioned(
                    key: const Key('alphabet-pressed-feedback'),
                    right: 46,
                    top: (letters.indexOf(pressed!) * height / 27 - 14).clamp(
                      0,
                      math.max(0, height - 48),
                    ),
                    child: IgnorePointer(
                      child: Container(
                        width: 72,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: accentColor(context),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          widget.available.contains(pressed)
                              ? pressed!
                              : '$pressed · 无',
                          textScaler: TextScaler.noScaling,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onPrimary,
                            fontSize: widget.available.contains(pressed)
                                ? 26
                                : 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
  Widget letterLabel(
    BuildContext context,
    String letter,
    String? current, {
    bool showText = true,
    bool compact = false,
  }) {
    return Container(
      key: ValueKey('${compact ? 'compact-' : ''}alphabet-letter-$letter'),
      margin: const EdgeInsets.symmetric(horizontal: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: current == letter ? accentColor(context) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
      ),
      child: showText
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.available.contains(letter))
                  Container(
                    key: ValueKey('alphabet-available-$letter'),
                    width: 3,
                    height: 3,
                    margin: const EdgeInsets.only(right: 3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: current == letter
                          ? Theme.of(context).colorScheme.onPrimary
                          : accentColor(context),
                    ),
                  ),
                Text(
                  letter,
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: widget.available.contains(letter)
                        ? FontWeight.w700
                        : FontWeight.w400,
                    decoration: widget.available.contains(letter)
                        ? TextDecoration.none
                        : TextDecoration.lineThrough,
                    color: current == letter
                        ? Theme.of(context).colorScheme.onPrimary
                        : widget.available.contains(letter)
                        ? accentColor(context)
                        : secondaryColor(context).withValues(alpha: .45),
                  ),
                ),
              ],
            )
          : null,
    );
  }
}
