import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals, setEquals;
import 'package:flutter/scheduler.dart';

import '../core/log.dart';
import 'danmaku_clock.dart';
import 'danmaku_correction.dart';
import 'danmaku_flights.dart';
import 'danmaku_preferences.dart';
import 'danmaku_sources.dart';
import 'danmaku_storage.dart';
import 'session.dart';

class DanmakuOverlay extends StatefulWidget {
  const DanmakuOverlay({
    super.key,
    required this.session,
    required this.identity,
    required this.compatible,
    required this.status,
    required this.createSource,
    required this.preferences,
    required this.controller,
  });
  final PlaybackSession session;
  final DanmakuPreferences preferences;
  final DanmakuOverlayController controller;
  final DanmakuSources Function() createSource;
  final DanmakuIdentity? identity;
  final Uri? compatible;
  final ValueNotifier<String> status;

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay>
    with SingleTickerProviderStateMixin {
  DanmakuSources? client;
  List<DanmakuTrack> tracks = [];
  final loaded = <DanmakuSegment, List<DanmakuComment>>{};
  final retryAt = <DanmakuSegment, DateTime>{};
  final retryFailures = <DanmakuSegment, int>{};
  final comments = ValueNotifier<List<DanmakuComment>>([]);
  final clock = ValueNotifier<double>(0);
  final rate = ValueNotifier<double>(1);
  final elapsed = Stopwatch()..start();
  late final Ticker ticker = createTicker(_paintFrame);
  Timer? poll, matchRetry;
  int matchAttempts = 0;
  final reading = <DanmakuSegment>{};
  final _reportedSegments = <String>{};
  bool rollingAdmitted = false, rollingVisible = false;
  final motionClock = DanmakuClock();
  _DanmakuPainter? painter;

  bool current(DanmakuSources source) =>
      mounted &&
      identical(client, source) &&
      !widget.session.closed &&
      widget.session.api.session == widget.session.account;

  @override
  void initState() {
    super.initState();
    if (!identical(widget.controller._local?.$1, widget.session)) {
      widget.controller._local = null;
    }
    widget.controller._owner = this;
    widget.session.addListener(updateClock);
    start();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged =
        oldWidget.compatible != widget.compatible ||
        oldWidget.preferences.compatible != widget.preferences.compatible ||
        oldWidget.preferences.automatic != widget.preferences.automatic ||
        !setEquals(oldWidget.preferences.hidden, widget.preferences.hidden);
    final trackOffsetsChanged = !mapEquals(
      oldWidget.preferences.delays,
      widget.preferences.delays,
    );
    if (sourceChanged ||
        (oldWidget.identity != widget.identity && tracks.isEmpty)) {
      start();
    } else if (oldWidget.preferences.appearance.delay !=
            widget.preferences.appearance.delay ||
        trackOffsetsChanged) {
      final source = client;
      if (source != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!current(source)) return;
          if (trackOffsetsChanged) {
            painter?.flights.replaceFeed();
            publish();
          }
          unawaited(fetch(source));
        });
      }
    }
  }

  void describe(String value) {
    final status = widget.status;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(widget.status, status)) status.value = value;
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void start({bool force = false, bool clear = false}) {
    matchRetry?.cancel();
    matchAttempts = 0;
    client?.close();
    client = null;
    poll?.cancel();
    poll = null;
    tracks = [];
    manualRequest++;
    _reportedSegments.clear();
    loaded.clear();
    retryAt.clear();
    retryFailures.clear();
    // A build can recreate the match. Defer painter notifications past layout.
    final id = widget.identity;
    final source = widget.createSource();
    client = source;
    reading.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current(source)) return;
      widget.controller.candidates.value = [];
      widget.controller.active.value = [];
      widget.controller.remembered.value =
          corrections.lookup(correctionKey) != null;
      if (clear) painter?.flights.clear();
      painter?.flights.replaceFeed();
      comments.value = [];
      updateClock();
      if (clear) return;
      final local = widget.controller._local;
      if (local != null &&
          identical(local.$1, widget.session) &&
          !widget.preferences.hidden.contains(local.$2.source)) {
        select(local.$2);
        return;
      }
      if (id == null) {
        widget.session.store.log.add(LogArea.player, '弹幕：等待有效片名、集号或时长');
        return;
      }
      widget.session.store.log.add(LogArea.player, '弹幕：开始查询公开来源');
      unawaited(match(source, id, restore: !force));
    });
    describe(
      clear
          ? '弹幕缓存已清空，可重新匹配'
          : !force && !widget.preferences.automatic
          ? '自动在线匹配已关闭'
          : id == null
          ? '等待片名、集号和时长'
          : '正在匹配弹幕…',
    );
  }

  List<Uri> get alternatives => DanmakuSources.compatibleAddresses(
    widget.preferences.compatible,
  ).where((uri) => uri != widget.compatible).toList();

  String get selectionKey {
    final account = widget.session.account;
    return jsonEncode([
      'selection',
      account.base.toString(),
      account.userId,
      widget.session.item.id,
      widget.identity?.title,
      widget.identity?.episode,
    ]);
  }

  DanmakuCorrections get corrections =>
      DanmakuCorrections(widget.session.store.prefs);
  String get correctionKey {
    final account = widget.session.account;
    return DanmakuCorrections.key(
      account.base.toString(),
      account.userId,
      widget.session.item.id,
    );
  }

  Future<void> match(
    DanmakuSources source,
    DanmakuIdentity id, {
    bool restore = false,
  }) async {
    final revision = selectionRevision;
    if (restore) {
      final own = corrections.lookup(correctionKey);
      final saved = own == null && widget.preferences.automatic
          ? await source.storage?.read(selectionKey)
          : null;
      final link =
          own ??
          (saved != null && saved.length <= 320
              ? utf8.decode(saved, allowMalformed: true)
              : null);
      if (!current(source) || revision != selectionRevision) return;
      if (link != null && Uri.tryParse(link)?.scheme == 'https') {
        describe('正在读取已保存的弹幕纠错…');
        final selected = await source.search(
          id,
          link,
          hidden: widget.preferences.hidden,
        );
        if (!current(source) || revision != selectionRevision) return;
        if (selected.length == 1) {
          select(selected.single, persist: own == null, restored: own != null);
          return;
        }
      }
      if (!widget.preferences.automatic) {
        if (link != null) describe('已保存的弹幕来源暂不可用');
        return;
      }
    }
    await source.match(
      id,
      compatible: widget.compatible,
      alternatives: alternatives,
      hidden: widget.preferences.hidden,
      onTrack: (track) {
        if (!current(source) || revision != selectionRevision) return;
        addTrack(source, track);
      },
    );
    if (current(source) && revision == selectionRevision && tracks.isEmpty) {
      scheduleMatchRetry(source, id);
    }
  }

  void scheduleMatchRetry(DanmakuSources source, DanmakuIdentity id) {
    if (widget.preferences.automatic && matchAttempts < 3) {
      describe('暂未匹配，将自动重试');
      matchRetry = Timer(Duration(seconds: [2, 15, 45][matchAttempts++]), () {
        if (current(source)) unawaited(match(source, id));
      });
    } else {
      describe('没有找到可确认的弹幕来源');
    }
  }

  void addTrack(DanmakuSources source, DanmakuTrack track) {
    if (widget.preferences.hidden.contains(track.source) ||
        tracks.length >= 12 ||
        (track.link != null &&
            tracks.any((loaded) => loaded.link == track.link))) {
      return;
    }
    tracks.add(track);
    widget.controller.active.value = List.unmodifiable(tracks);
    widget.session.store.log.add(LogArea.player, '弹幕：${track.source}匹配成功');
    describe('已匹配 ${tracks.map((t) => t.source).join('、')}，正在读取弹幕');
    poll ??= Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => fetch(source),
    );
    unawaited(fetch(source));
  }

  Future<void> search(String query) async {
    final id = widget.identity;
    final source = client;
    if (id == null || source == null) return;
    final request = ++manualRequest;
    widget.controller.candidates.value = [];
    describe('正在查找在线弹幕…');
    final tracks = await source.search(
      id,
      query,
      compatible: widget.compatible,
      alternatives: alternatives,
      hidden: widget.preferences.hidden,
    );
    if (!current(source) || request != manualRequest) return;
    widget.controller.candidates.value = tracks;
    describe(tracks.isEmpty ? '没有找到可确认的弹幕来源' : '找到 ${tracks.length} 个候选来源');
  }

  int manualRequest = 0, selectionRevision = 0;
  void select(
    DanmakuTrack track, {
    bool persist = false,
    bool restored = false,
  }) {
    final source = client;
    if (source == null ||
        !current(source) ||
        widget.preferences.hidden.contains(track.source)) {
      return;
    }
    // Replace future admissions while already visible comments finish.
    selectionRevision++;
    reading.clear();
    matchRetry?.cancel();
    final link = track.link;
    final revision = selectionRevision;
    if (persist && link != null && Uri.tryParse(link)?.scheme == 'https') {
      unawaited(
        corrections.save(correctionKey, link).then((ok) {
          if (!current(source) || revision != selectionRevision) return;
          widget.controller.remembered.value = ok;
          if (!ok) describe('已切换弹幕，但暂时无法保存纠错');
        }),
      );
    }
    tracks = [];
    loaded.clear();
    retryAt.clear();
    retryFailures.clear();
    comments.value = [];
    painter?.flights.replaceFeed();
    addTrack(source, track);
    if (restored) describe('已应用本机保存的弹幕纠错');
  }

  Future<void> forget() async {
    final source = client;
    if (source == null || !current(source)) return;
    final revision = ++selectionRevision;
    final ok = await corrections.save(correctionKey, null);
    if (ok) await source.storage?.remove(selectionKey);
    if (!current(source) || revision != selectionRevision) return;
    if (!ok) {
      describe('暂时无法清除已保存的纠错');
      return;
    }
    widget.controller._local = null;
    start(force: true);
  }

  double get mediaTime => math.max(
    0,
    widget.session.position.inMilliseconds / 1000 -
        widget.preferences.appearance.delay,
  );

  Future<void> fetch(DanmakuSources source) async {
    if (!current(source) || reading.length >= 3) return;
    final revision = selectionRevision;
    final owners = <DanmakuSegment, DanmakuTrack>{
      for (final track in tracks)
        for (final segment in track.allSegments)
          if (withinWindow(track, segment)) segment: track,
    };
    final wanted = owners.keys.toSet();
    final changed = loaded.keys.any((s) => !wanted.contains(s));
    loaded.removeWhere((s, _) => !wanted.contains(s));
    retryAt.removeWhere((s, _) => !wanted.contains(s));
    retryFailures.removeWhere((s, _) => !wanted.contains(s));
    if (changed) publish();
    final candidates =
        wanted
            .where(
              (s) =>
                  !loaded.containsKey(s) &&
                  !reading.contains(s) &&
                  (retryAt[s]?.isAfter(DateTime.now()) != true),
            )
            .toList()
          ..sort((a, b) {
            double distance(DanmakuSegment s) {
              final time = sourceTime(owners[s]!);
              return s.start <= time && s.end > time
                  ? 0
                  : math.min((s.start - time).abs(), (s.end - time).abs());
            }

            return distance(a).compareTo(distance(b));
          });
    await Future.wait(
      candidates.take(3 - reading.length).toList().map((segment) async {
        final owner = owners[segment]!;
        reading.add(segment);
        try {
          final rows = await segment.load();
          if (current(source) &&
              revision == selectionRevision &&
              tracks.contains(owner) &&
              withinWindow(owner, segment)) {
            loaded[segment] = rows;
            if (rows.isNotEmpty && _reportedSegments.add(owner.source)) {
              widget.session.store.log.add(
                LogArea.player,
                '弹幕：${owner.source}已读取分段，有效条数=${rows.length}',
              );
            }
            publish();
          }
        } catch (_) {
          if (current(source) &&
              revision == selectionRevision &&
              tracks.any((track) => track.allSegments.contains(segment))) {
            final failures = retryFailures.update(
              segment,
              (n) => n + 1,
              ifAbsent: () => 0,
            );
            retryAt[segment] = DateTime.now().add(
              Duration(seconds: [2, 15, 45][failures.clamp(0, 2)]),
            );
            if (comments.value.isEmpty) describe('已匹配，暂时读不到弹幕');
          }
        } finally {
          if (current(source) && revision == selectionRevision) {
            reading.remove(segment);
          }
        }
      }),
    );
  }

  double sourceTime(DanmakuTrack track) =>
      mediaTime - (widget.preferences.delays[track.source] ?? 0);

  bool withinWindow(DanmakuTrack track, DanmakuSegment segment) {
    final time = sourceTime(track);
    return segment.end > time - 12 && segment.start < time + 48;
  }

  void publish() {
    final unique = <(int, String, int)>{};
    final rows =
        [
              for (final track in tracks)
                for (final segment in track.allSegments)
                  for (final comment
                      in loaded[segment] ?? const <DanmakuComment>[])
                    if (widget.preferences.delays[track.source]
                        case final delay?)
                      DanmakuComment(
                        comment.time + delay,
                        comment.text,
                        comment.mode,
                        comment.color,
                      )
                    else
                      comment,
            ]
            .where((c) => unique.add(((c.time * 1000).round(), c.text, c.mode)))
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    comments.value = rows;
    if (rows.isNotEmpty) {
      describe('已加载 ${tracks.map((t) => t.source).join('、')}');
    }
    updateClock();
  }

  void updateClock() {
    final state = widget.session.backend.snapshot;
    final playing =
        state.playing &&
        !state.buffering &&
        !widget.session.seeking &&
        !widget.session.closed &&
        (comments.value.isNotEmpty ||
            painter?.flights.active.isNotEmpty == true);
    if (playing && !ticker.isActive) {
      ticker.start();
    } else if (!playing && ticker.isActive) {
      ticker.stop();
    }
    _paintFrame(Duration.zero);
  }

  void _paintFrame(Duration _) {
    final session = widget.session;
    final snapshot = session.backend.snapshot;
    rate.value = session.speed;
    if (comments.value.isEmpty && painter?.flights.active.isEmpty != false) {
      if (ticker.isActive) ticker.stop();
      motionClock.idle();
      return;
    }
    if (motionClock.update(
      now: elapsed.elapsedMicroseconds / Duration.microsecondsPerSecond,
      position: session.position.inMilliseconds / 1000,
      speed: session.speed,
      running: snapshot.playing && !snapshot.buffering && !session.seeking,
      revision: session.seekRevision,
      seeking: session.seeking,
    )) {
      painter?.flights.clear();
    }
    clock.value = motionClock.value;
  }

  @override
  Widget build(BuildContext context) {
    final safe = MediaQuery.paddingOf(context);
    final appearance = widget.preferences.appearance;
    final old = painter;
    if (old == null || old.safe != safe || old.appearance != appearance) {
      final before = old?.appearance;
      final reuseLayouts =
          before != null &&
          before.fontSize == appearance.fontSize &&
          before.adaptive == appearance.adaptive &&
          before.opacity == appearance.opacity;
      if (!reuseLayouts) old?.release();
      painter = _DanmakuPainter(
        comments,
        clock,
        rate,
        safe,
        appearance,
        onRolling: (visible) {
          if (visible ? rollingVisible : rollingAdmitted) return;
          if (visible) {
            rollingVisible = true;
          } else {
            rollingAdmitted = true;
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !widget.session.closed) {
              widget.session.store.log.add(
                LogArea.player,
                visible ? '弹幕：滚动条目进入画面' : '弹幕：滚动条目已入轨',
              );
            }
          });
        },
        flights: old?.flights,
        layouts: reuseLayouts ? old?.layouts : null,
        layoutWidth: reuseLayouts ? old?.layoutWidth : null,
        layoutFont: reuseLayouts ? old?.layoutFont : null,
      );
    }
    return IgnorePointer(
      child: RepaintBoundary(child: CustomPaint(painter: painter)),
    );
  }

  @override
  void dispose() {
    matchRetry?.cancel();
    if (identical(widget.controller._owner, this)) {
      widget.controller._owner = null;
    }
    widget.session.removeListener(updateClock);
    poll?.cancel();
    client?.close();
    client = null;
    ticker.dispose();
    painter?.release();
    comments.dispose();
    clock.dispose();
    rate.dispose();
    super.dispose();
  }
}

class DanmakuOverlayController {
  _DanmakuOverlayState? _owner;
  (PlaybackSession, DanmakuTrack)? _local;
  final candidates = ValueNotifier<List<DanmakuTrack>>([]);
  final active = ValueNotifier<List<DanmakuTrack>>([]);
  final remembered = ValueNotifier<bool>(false);

  void retry() {
    _local = null;
    _owner?.start(force: true);
  }

  void clear() {
    _local = null;
    unawaited(DanmakuStorage.local.clear());
    _owner?.start(clear: true);
  }

  Future<void> search(String query) async => _owner?.search(query);
  void select(DanmakuTrack track) {
    if (!candidates.value.contains(track)) return;
    _local = null;
    _owner?.select(track, persist: true);
  }

  void add(DanmakuTrack track) {
    final owner = _owner;
    final client = owner?.client;
    if (owner != null &&
        client != null &&
        owner.current(client) &&
        candidates.value.contains(track)) {
      owner.addTrack(client, track);
    }
  }

  Future<void> forget() async => _owner?.forget();

  void selectLocal(PlaybackSession session, DanmakuTrack track) {
    _local = (session, track);
    final owner = _owner;
    if (owner != null && identical(owner.widget.session, session)) {
      owner.select(track);
    }
  }

  void dispose() {
    candidates.dispose();
    active.dispose();
    remembered.dispose();
  }
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter(
    this.comments,
    this.clock,
    this.rate,
    this.safe,
    this.appearance, {
    required this.onRolling,
    DanmakuFlights? flights,
    Map<DanmakuComment, TextPainter>? layouts,
    this.layoutWidth,
    this.layoutFont,
  }) : flights = flights ?? DanmakuFlights(),
       layouts = layouts ?? {},
       super(repaint: Listenable.merge([comments, clock, rate]));
  final ValueNotifier<List<DanmakuComment>> comments;
  final ValueNotifier<double> clock;
  final ValueNotifier<double> rate;
  final EdgeInsets safe;
  final DanmakuAppearance appearance;
  final ValueChanged<bool> onRolling;
  final DanmakuFlights flights;
  final Map<DanmakuComment, TextPainter> layouts;
  double? layoutWidth, layoutFont;

  void release() {
    for (final layout in layouts.values) {
      layout.dispose();
    }
    layouts.clear();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width - safe.horizontal;
    final top = safe.top + 8;
    final subtitleReserve = (size.height * .16).clamp(42.0, 105.0);
    final available = size.height - top - safe.bottom - subtitleReserve;
    if (width <= 0 || available <= 0) return;
    final fontSize =
        appearance.fontSize *
        (appearance.adaptive ? (size.shortestSide / 650).clamp(.68, 1.25) : 1);
    final line = fontSize * 1.35 + 4;
    final area = math.min(
      available,
      size.height * math.min(appearance.area, .72) - top,
    );
    final lanes = (area / line).floor().clamp(0, 24);
    TextPainter textFor(DanmakuComment row) => layouts.putIfAbsent(
      row,
      () => TextPainter(
        text: TextSpan(
          text: row.text,
          style: TextStyle(
            color: Color(
              0xff000000 | row.color,
            ).withValues(alpha: appearance.opacity),
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            shadows: const [
              Shadow(color: Colors.black, blurRadius: 3, offset: Offset(1, 1)),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: width * .7),
    );

    final metricsChanged = layoutWidth != width || layoutFont != fontSize;
    if (metricsChanged) {
      release();
      layoutWidth = width;
      layoutFont = fontSize;
    }
    flights.reflow(
      width,
      size.height,
      (available / line).floor().clamp(0, 24),
      (row) => textFor(row).width,
    );
    if (metricsChanged) {
      for (final row in flights.active) {
        row.width = textFor(row.comment).width;
      }
    }
    final time = clock.value;
    flights.advance(
      comments: comments.value,
      time: time,
      viewport: width,
      lanes: lanes,
      appearance: appearance,
      playbackRate: rate.value,
      measure: (row) => textFor(row).width,
    );
    canvas.save();
    // Area controls admission only. Existing rows can finish anywhere inside
    // the safe overlay, which still reserves room for subtitles.
    canvas.clipRect(Rect.fromLTWH(safe.left, top, width, available));
    for (final row in flights.active) {
      if (row.comment.mode == 1 && !appearance.scroll ||
          row.comment.mode == 4 && !appearance.bottom ||
          row.comment.mode == 5 && !appearance.top) {
        continue;
      }
      final text = textFor(row.comment);
      final x = safe.left + row.x(flights.motion, width);
      final y = top + row.lane * line;
      if (row.comment.mode == 1) {
        onRolling(false);
        if (x < safe.left + width &&
            x + text.width > safe.left &&
            y < top + available) {
          onRolling(true);
        }
      }
      if (appearance.background) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, text.width, text.height),
            const Radius.circular(3),
          ),
          Paint()
            ..color = Colors.black.withValues(alpha: appearance.opacity * .5),
        );
      }
      text.paint(canvas, Offset(x, y));
    }
    canvas.restore();
    if (layouts.length > 72) {
      final live = flights.active.map((row) => row.comment).toSet();
      layouts.removeWhere((row, text) {
        if (live.contains(row)) return false;
        text.dispose();
        return true;
      });
    }
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) =>
      safe != oldDelegate.safe || appearance != oldDelegate.appearance;
}
