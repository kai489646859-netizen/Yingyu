import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/log.dart';
import 'danmaku_clock.dart';
import 'danmaku_flights.dart';
import 'danmaku_preferences.dart';
import 'danmaku_sources.dart';
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
  final comments = ValueNotifier<List<DanmakuComment>>([]);
  final clock = ValueNotifier<double>(0);
  final elapsed = Stopwatch()..start();
  late final Ticker ticker = createTicker(_paintFrame);
  Timer? poll;
  bool reading = false;
  final _reportedSegments = <String>{};
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
        oldWidget.preferences.automatic != widget.preferences.automatic;
    if (sourceChanged ||
        (oldWidget.identity != widget.identity && tracks.isEmpty)) {
      start();
    } else if (oldWidget.preferences.appearance.delay !=
        widget.preferences.appearance.delay) {
      unawaited(fetch(client!));
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
    client?.close();
    client = null;
    poll?.cancel();
    poll = null;
    tracks = [];
    manualRequest++;
    _reportedSegments.clear();
    loaded.clear();
    retryAt.clear();
    // A build can recreate the match. Defer painter notifications past layout.
    final id = widget.identity;
    final source = widget.createSource();
    client = source;
    reading = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!current(source)) return;
      widget.controller.candidates.value = [];
      if (clear) painter?.flights.clear();
      comments.value = [];
      updateClock();
      if (clear) return;
      final local = widget.controller._local;
      if (local != null && identical(local.$1, widget.session)) {
        select(local.$2);
        return;
      }
      if (!force && !widget.preferences.automatic) return;
      if (id == null) {
        widget.session.store.log.add(LogArea.player, '弹幕：等待有效片名、集号或时长');
        return;
      }
      widget.session.store.log.add(LogArea.player, '弹幕：开始查询公开来源');
      unawaited(match(source, id));
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

  Future<void> match(DanmakuSources source, DanmakuIdentity id) async {
    final revision = selectionRevision;
    await source.match(
      id,
      compatible: widget.compatible,
      onTrack: (track) {
        if (!current(source) || revision != selectionRevision) return;
        addTrack(source, track);
      },
    );
    if (current(source) && tracks.isEmpty) describe('没有找到可确认的弹幕来源');
  }

  void addTrack(DanmakuSources source, DanmakuTrack track) {
    tracks.add(track);
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
    describe('正在查找在线弹幕…');
    final tracks = await source.search(
      id,
      query,
      compatible: widget.compatible,
    );
    if (!current(source) || request != manualRequest) return;
    widget.controller.candidates.value = tracks;
    describe(tracks.isEmpty ? '没有找到可确认的弹幕来源' : '找到 ${tracks.length} 个候选来源');
  }

  int manualRequest = 0, selectionRevision = 0;
  void select(DanmakuTrack track) {
    final source = client;
    if (source == null || !current(source)) return;
    // Replace future admissions while already visible comments finish.
    selectionRevision++;
    tracks = [];
    loaded.clear();
    retryAt.clear();
    comments.value = [];
    addTrack(source, track);
  }

  double get mediaTime => math.max(
    0,
    widget.session.position.inMilliseconds / 1000 -
        widget.preferences.appearance.delay,
  );

  Future<void> fetch(DanmakuSources source) async {
    if (!current(source) || reading) return;
    reading = true;
    try {
      final time = mediaTime;
      final wanted = <DanmakuSegment>{
        for (final track in tracks)
          ...track.segments.where(
            (s) => s.end > time - 12 && s.start < time + 48,
          ),
      };
      final changed = loaded.keys.any((s) => !wanted.contains(s));
      loaded.removeWhere((s, _) => !wanted.contains(s));
      retryAt.removeWhere((s, _) => !wanted.contains(s));
      if (changed) publish();
      final candidates =
          wanted
              .where(
                (s) =>
                    !loaded.containsKey(s) &&
                    (retryAt[s]?.isAfter(DateTime.now()) != true),
              )
              .toList()
            ..sort(
              (a, b) =>
                  (a.start - time).abs().compareTo((b.start - time).abs()),
            );
      await Future.wait(
        candidates.take(3).map((segment) async {
          try {
            final rows = await segment.load();
            if (current(source) &&
                tracks.any((track) => track.segments.contains(segment)) &&
                segment.end > mediaTime - 12 &&
                segment.start < mediaTime + 48) {
              loaded[segment] = rows;
              final owner = tracks.firstWhere(
                (track) => track.segments.contains(segment),
              );
              if (rows.isNotEmpty && _reportedSegments.add(owner.source)) {
                widget.session.store.log.add(
                  LogArea.player,
                  '弹幕：${owner.source}已读取分段，有效条数=${rows.length}',
                );
              }
              publish();
            }
          } catch (_) {
            if (current(source)) {
              retryAt[segment] = DateTime.now().add(
                const Duration(seconds: 30),
              );
              if (comments.value.isEmpty) describe('已匹配，暂时读不到弹幕');
            }
          }
        }),
      );
    } finally {
      if (current(source)) reading = false;
    }
  }

  void publish() {
    final unique = <(int, String)>{};
    final rows =
        loaded.values
            .expand((value) => value)
            .where((c) => unique.add(((c.time * 2).round(), c.text)))
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
        safe,
        appearance,
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
    super.dispose();
  }
}

class DanmakuOverlayController {
  _DanmakuOverlayState? _owner;
  (PlaybackSession, DanmakuTrack)? _local;
  final candidates = ValueNotifier<List<DanmakuTrack>>([]);

  void retry() {
    _local = null;
    _owner?.start(force: true);
  }

  void clear() {
    _local = null;
    _owner?.start(clear: true);
  }

  Future<void> search(String query) async => _owner?.search(query);
  void select(DanmakuTrack track) {
    _local = null;
    _owner?.select(track);
  }

  void selectLocal(PlaybackSession session, DanmakuTrack track) {
    _local = (session, track);
    final owner = _owner;
    if (owner != null && identical(owner.widget.session, session)) {
      owner.select(track);
    }
  }

  void dispose() => candidates.dispose();
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter(
    this.comments,
    this.clock,
    this.safe,
    this.appearance, {
    DanmakuFlights? flights,
    Map<DanmakuComment, TextPainter>? layouts,
    this.layoutWidth,
    this.layoutFont,
  }) : flights = flights ?? DanmakuFlights(),
       layouts = layouts ?? {},
       super(repaint: Listenable.merge([comments, clock]));
  final ValueNotifier<List<DanmakuComment>> comments;
  final ValueNotifier<double> clock;
  final EdgeInsets safe;
  final DanmakuAppearance appearance;
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

    if (layoutWidth != width || layoutFont != fontSize) {
      release();
      layoutWidth = width;
      layoutFont = fontSize;
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
      final x = safe.left + row.x(time, width);
      final y = top + row.lane * line;
      if (appearance.background) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x - 3, y, text.width + 6, text.height),
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
