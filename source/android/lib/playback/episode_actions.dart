import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/models.dart';
import '../core/personal_library.dart';
import '../ui/style.dart';
import 'session.dart';
import 'skip_policy.dart';

/// Per-media skip policy and the existing cancellable natural-end countdown.
/// Skips use session.seek; episode changes retain the save/close/open path.
class EpisodeActions extends StatefulWidget {
  const EpisodeActions({
    super.key,
    required this.session,
    required this.next,
    required this.enabled,
    required this.controls,
    required this.onNext,
  });
  final PlaybackSession session;
  final MediaItem? next;
  final bool enabled, controls;
  final Future<void> Function(MediaItem) onNext;
  @override
  State<EpisodeActions> createState() => _EpisodeActionsState();
}

class _EpisodeActionsState extends State<EpisodeActions> {
  Timer? timer, autoTimer, returnTimer;
  int? remaining;
  SkipCountdown? pendingSkip;
  String? pendingSignature;
  int? pendingRevision;
  Duration? returnPosition, returnTarget;
  SkipPart? returnPart;
  bool consumed = false, seeking = false, openingIntroShown = false;
  SkipPolicy skipPolicy = SkipPolicy();
  int seenSkipRevision = 0;
  int advanceRevision = 0;
  String? error;
  PlaybackSession get session => widget.session;
  bool get available =>
      widget.enabled &&
      session.ready &&
      !session.closed &&
      session.error == null &&
      !session.background &&
      session.api.session == session.account;
  // Session confirms only real EOF. A late seek command reply can clear the
  // backend's transient completed flag after that EOF was already observed.
  bool get ended => session.completed;
  bool get canAdvance =>
      canOffer && ended && !session.backend.snapshot.buffering;
  bool get canOffer =>
      available &&
      !seeking &&
      !session.seeking &&
      session.store.autoNext &&
      widget.next != null &&
      widget.next!.type == 'Episode' &&
      widget.next!.id != session.item.id &&
      widget.next!.data['SeriesId'] == session.item.data['SeriesId'];

  @override
  void initState() {
    super.initState();
    seenSkipRevision = session.store.personal.skipRevision(session.account);
    session.addListener(changed);
    session.store.addListener(changed);
    session.store.personal.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) changed();
    });
  }

  @override
  void didUpdateWidget(EpisodeActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != session) {
      timer?.cancel();
      cancelAuto();
      clearReturn();
      oldWidget.session.removeListener(changed);
      oldWidget.session.store.removeListener(changed);
      oldWidget.session.store.personal.removeListener(changed);
      remaining = null;
      consumed = seeking = false;
      openingIntroShown = false;
      error = null;
      seenSkipRevision = session.store.personal.skipRevision(session.account);
      skipPolicy = SkipPolicy();
      session.addListener(changed);
      session.store.addListener(changed);
      session.store.personal.addListener(changed);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) changed();
    });
  }

  void cancel() {
    advanceRevision++;
    timer?.cancel();
    timer = null;
    remaining = null;
    consumed = true;
  }

  void changed() {
    if (!mounted) return;
    if (!available || (session.seeking && !seeking)) {
      cancelAuto();
      clearReturn();
    } else if (!seeking &&
        returnTarget != null &&
        session.position < returnTarget!) {
      clearReturn();
    }
    if (remaining != null && !canOffer) cancel();
    if (!openingIntroShown && available && session.openingIntro != null) {
      openingIntroShown = true;
      skipPolicy.consume(SkipPart.intro);
      returnPosition = session.openingIntro!.from;
      returnTarget = session.openingIntro!.to;
      returnPart = SkipPart.intro;
      returnTimer = Timer(const Duration(seconds: 5), () {
        if (mounted) setState(clearReturn);
      });
    }
    final left = session.backend.snapshot.duration - session.position;
    if (!consumed &&
        canOffer &&
        !ended &&
        session.backend.snapshot.duration > const Duration(seconds: 5) &&
        left > Duration.zero &&
        left <= const Duration(seconds: 5)) {
      remaining = (left.inMilliseconds / 1000).ceil();
    } else if (!ended) {
      remaining = null;
    }
    if (ended && !consumed && canAdvance) {
      consumed = true;
      if (returnPart == SkipPart.credits && returnPosition != null) {
        // Keep the existing return-to-credits action after an explicit skip.
        // Natural EOF has no post-end timer.
        remaining = 5;
        timer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted || !canAdvance) {
            cancel();
            if (mounted) setState(() {});
          } else if (remaining! <= 1) {
            unawaited(advance());
          } else {
            setState(() => remaining = remaining! - 1);
          }
        });
      } else {
        // Real EOF remains the boundary. The opportunity to cancel was shown
        // over the final media seconds, so no second wall-clock wait is needed.
        final revision = advanceRevision;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && revision == advanceRevision && canAdvance) {
            unawaited(advance());
          }
        });
      }
    }
    final resolved = readRule();
    final revision = session.store.personal.skipRevision(session.account);
    if (revision != seenSkipRevision) {
      seenSkipRevision = revision;
      cancelAuto();
      // Saving even an unchanged range is configuration, not an instruction to
      // seek when the editor closes. Other personal-list edits do not do this.
      skipPolicy.suppressCurrent(
        resolved?.rule,
        session.position,
        session.backend.snapshot.duration,
      );
    }
    maybeAutoSkip(resolved);
    setState(() {});
  }

  ResolvedSkipRule? readRule() {
    try {
      return session.store.personal.resolveSkipRule(
        session.account,
        session.currentMetadata,
      );
    } catch (e) {
      error = safeError(e);
      return null;
    }
  }

  String signature(ResolvedSkipRule? value) =>
      jsonEncode([value?.scope.name, value?.rule.toJson()]);

  bool get canAutoSkip =>
      available &&
      !session.seeking &&
      !seeking &&
      !ended &&
      !session.loading &&
      session.backend.snapshot.playing &&
      !session.backend.snapshot.buffering &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  void maybeAutoSkip(ResolvedSkipRule? resolved) {
    final state = session.backend.snapshot;
    if (pendingSkip != null) {
      if (!validPending(resolved) || !available || session.seeking || ended) {
        cancelAuto();
      } else if (canAutoSkip) {
        scheduleAuto();
      } else {
        pauseAuto();
      }
      return;
    }
    final target = skipPolicy.automatic(
      rule: resolved?.rule,
      position: session.position,
      duration: state.duration,
      allowed: canAutoSkip,
      seeking: session.seeking,
    );
    if (target == null) return;
    pendingSkip = SkipCountdown(target);
    pendingSignature = signature(resolved);
    pendingRevision = session.store.personal.skipRevision(session.account);
    scheduleAuto();
  }

  bool validPending(ResolvedSkipRule? resolved) {
    final pending = pendingSkip;
    if (pending == null ||
        pendingSignature != signature(resolved) ||
        pendingRevision !=
            session.store.personal.skipRevision(session.account)) {
      return false;
    }
    final rule = resolved?.rule, duration = session.backend.snapshot.duration;
    return pending.target.part == SkipPart.intro
        ? rule?.autoIntro == true &&
              rule!.introContains(session.position, duration)
        : rule?.autoCredits == true &&
              rule!.creditsContains(session.position, duration);
  }

  void pauseAuto() {
    autoTimer?.cancel();
    autoTimer = null;
  }

  void cancelAuto() {
    pauseAuto();
    pendingSkip = null;
    pendingSignature = null;
    pendingRevision = null;
  }

  SkipTarget pendingTarget(ResolvedSkipRule resolved) => SkipTarget(
    pendingSkip!.target.part,
    pendingSkip!.target.part == SkipPart.credits
        ? session.backend.snapshot.duration
        : resolved.rule.intro!.end,
  );

  void scheduleAuto() {
    if (autoTimer != null || pendingSkip == null || !canAutoSkip) return;
    autoTimer = Timer(const Duration(seconds: 1), () {
      autoTimer = null;
      if (!mounted) return;
      final resolved = readRule();
      if (!validPending(resolved) || !available || session.seeking || ended) {
        setState(cancelAuto);
        return;
      }
      if (!canAutoSkip) return;
      if (pendingSkip!.tick(allowed: true)) {
        final target = pendingTarget(resolved!);
        setState(cancelAuto);
        unawaited(skip(target));
      } else {
        setState(() {});
        scheduleAuto();
      }
    });
  }

  Future<void> skipNow() async {
    final resolved = readRule();
    if (!available || !validPending(resolved)) return;
    await skip(pendingTarget(resolved!));
  }

  void clearReturn() {
    returnTimer?.cancel();
    returnTimer = null;
    returnPosition = returnTarget = null;
    returnPart = null;
  }

  Future<void> watchAgain() async {
    final target = returnPosition, owner = session;
    if (target == null ||
        !available ||
        seeking ||
        session.seeking ||
        session.backend.snapshot.buffering) {
      return;
    }
    setState(() {
      cancel();
      cancelAuto();
      clearReturn();
      seeking = true;
      error = null;
    });
    try {
      await owner.seek(target, source: SeekSource.menu);
    } catch (e) {
      if (mounted && session == owner) setState(() => error = safeError(e));
    } finally {
      if (mounted && session == owner) {
        seeking = false;
        changed();
      }
    }
  }

  Future<void> advance({bool manual = false}) async {
    if (!(manual ? canOffer : canAdvance)) {
      setState(cancel);
      return;
    }
    final target = widget.next!;
    setState(cancel);
    await widget.onNext(target);
  }

  Future<void> skip(SkipTarget target) async {
    if (seeking ||
        !available ||
        session.seeking ||
        session.backend.snapshot.buffering ||
        ended) {
      return;
    }
    skipPolicy.consume(target.part);
    final owner = session, from = session.position;
    setState(() {
      cancelAuto();
      clearReturn();
      seeking = true;
      error = null;
    });
    try {
      await owner.seek(target.position, source: SeekSource.menu);
      if (mounted && session == owner && available) {
        returnPosition = from;
        returnTarget = target.position;
        returnPart = target.part;
        returnTimer = Timer(const Duration(seconds: 5), () {
          if (mounted) setState(clearReturn);
        });
      }
    } catch (e) {
      if (mounted && session == owner) setState(() => error = safeError(e));
    } finally {
      if (mounted && session == owner) {
        seeking = false;
        changed();
      }
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    cancelAuto();
    clearReturn();
    session.removeListener(changed);
    session.store.removeListener(changed);
    session.store.personal.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rule = readRule()?.rule;
    final duration = session.backend.snapshot.duration;
    final showIntro =
        available &&
        !session.seeking &&
        !session.backend.snapshot.buffering &&
        !ended &&
        rule?.introContains(session.position, duration) == true;
    final showCredits =
        available &&
        !session.seeking &&
        !session.backend.snapshot.buffering &&
        !ended &&
        rule?.creditsContains(session.position, duration) == true;
    if (!available ||
        (remaining == null &&
            !showIntro &&
            !showCredits &&
            returnPosition == null &&
            error == null)) {
      return const SizedBox.shrink();
    }
    return Stack(
      children: [
        Positioned(
          right: 16,
          bottom: widget.controls ? 156 : 28,
          width: math.min(360, MediaQuery.sizeOf(context).width - 32),
          child: SafeArea(
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: playerPanelColor(context),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (remaining != null) ...[
                      Text(
                        '$remaining 秒后播放下一集',
                        key: const Key('next-countdown'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                      Text(
                        widget.next!.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => setState(cancel),
                            child: const Text('取消连播'),
                          ),
                          TextButton(
                            onPressed: () => advance(manual: true),
                            child: const Text('立即播放'),
                          ),
                        ],
                      ),
                    ],
                    if (pendingSkip != null && (showIntro || showCredits)) ...[
                      Text(
                        '${pendingSkip!.remaining} 秒后跳过${pendingSkip!.target.part == SkipPart.intro ? '片头' : '片尾'}',
                        key: const Key('auto-skip-countdown'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                      Wrap(
                        alignment: WrapAlignment.center,
                        children: [
                          TextButton(
                            onPressed: seeking ? null : skipNow,
                            child: const Text('立即跳过'),
                          ),
                          TextButton(
                            onPressed: () => setState(cancelAuto),
                            child: const Text('本次不跳'),
                          ),
                        ],
                      ),
                    ],
                    if (showIntro && pendingSkip?.target.part != SkipPart.intro)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        onPressed: seeking
                            ? null
                            : () => skip(
                                SkipTarget(SkipPart.intro, rule!.intro!.end),
                              ),
                        child: Text(
                          seeking ? '跳转中…' : '跳过片头',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    if (showCredits &&
                        pendingSkip?.target.part != SkipPart.credits)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        onPressed: seeking
                            ? null
                            : () =>
                                  skip(SkipTarget(SkipPart.credits, duration)),
                        child: Text(
                          seeking ? '跳转中…' : '跳过片尾',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    if (returnPosition != null) ...[
                      Text(
                        '已跳过${returnPart == SkipPart.intro ? '片头' : '片尾'}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                      TextButton(
                        key: const Key('skip-return'),
                        onPressed:
                            seeking ||
                                session.seeking ||
                                session.backend.snapshot.buffering
                            ? null
                            : watchAgain,
                        child: const Text('返回观看'),
                      ),
                    ],
                    if (error != null)
                      Text(error!, style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
