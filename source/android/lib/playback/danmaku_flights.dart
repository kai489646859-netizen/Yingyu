import 'dart:collection';
import 'dart:math' as math;

import 'danmaku_preferences.dart';
import 'danmaku_sources.dart';

final _featuredSeparators = RegExp(r'[\p{White_Space}\p{P}]', unicode: true);

class DanmakuFlight {
  DanmakuFlight(this.comment, this.lane, this.started, this.width, this.travel);
  final DanmakuComment comment;
  int lane;
  double started, travel;
  double width;

  double x(double time, double viewport) => comment.mode == 1
      ? viewport - viewport * (time - started) / travel
      : (viewport - width) / 2;

  bool expired(double time, double viewport) =>
      comment.mode == 1 ? x(time, viewport) + width <= 0 : time - started >= 4;

  bool canFollow(double time, double viewport, double nextTravel) {
    final gap = viewport - (x(time, viewport) + width);
    if (nextTravel >= travel) return gap >= 24;
    final remaining = math.max(
      0.0,
      travel * (1 + width / viewport) - (time - started),
    );
    final closingSpeed = viewport / nextTravel - viewport / travel;
    return gap >= 24 + closingSpeed * remaining;
  }

  void resize(double time, double previous, double viewport, double newWidth) {
    if (comment.mode == 1 && previous != viewport) {
      final oldSpan = previous + width, newSpan = viewport + newWidth;
      final progress = (previous - x(time, previous)) / oldSpan;
      travel *= (viewport * oldSpan) / (previous * newSpan);
      started = time - progress * newSpan * travel / viewport;
    }
    width = newWidth;
  }
}

/// Owns the lifetime of visible comments. The incoming feed may be replaced
/// after any network segment without reassigning already visible lanes.
class DanmakuFlights {
  final active = <DanmakuFlight>[];
  final _repeats = <(String, int), (double, int)>{};
  final _pending = Queue<(DanmakuComment, double)>();
  final _recent = <(int, String, int)>{};
  double? _previous;
  double _feedThrough = 0, _epochStart = 0, _delay = 0;
  double _motion = 0, _rate = 1;
  double get motion => _motion;
  List<DanmakuComment>? _feed;
  bool _featured = false;
  double _lastFeaturedRolling = double.negativeInfinity;
  (double, double)? _viewport;

  void replaceFeed() => _pending.clear();

  void reflow(
    double width,
    double height,
    int safeLanes,
    double Function(DanmakuComment) measure,
  ) {
    final old = _viewport;
    _viewport = (width, height);
    if (old == null || old == _viewport) return;
    final occupied = <int>{
      for (final row in active)
        if (row.lane < safeLanes) row.lane,
    };
    for (final row in active) {
      row.resize(_motion, old.$1, width, measure(row.comment));
      if (row.lane < safeLanes) continue;
      for (var lane = 0; lane < safeLanes; lane++) {
        final candidate = row.comment.mode == 4 ? safeLanes - lane - 1 : lane;
        if (occupied.add(candidate)) {
          row.lane = candidate;
          break;
        }
      }
    }
  }

  void clear() {
    active.clear();
    _resetFeatured();
    _pending.clear();
    _recent.clear();
    _feed = null;
    _previous = null;
  }

  void advance({
    required List<DanmakuComment> comments,
    required double time,
    required double viewport,
    required int lanes,
    required DanmakuAppearance appearance,
    required double Function(DanmakuComment) measure,
    double playbackRate = 1,
  }) {
    final previous = _previous;
    if (previous == null || time < previous || time - previous > 1) {
      clear();
      _previous = time;
      _motion = time;
      _rate = playbackRate;
      _feed = comments;
      _delay = appearance.delay;
      _epochStart = _feedThrough = time - _delay;
      return;
    }
    if (_featured != appearance.featured) {
      _featured = appearance.featured;
      _resetFeatured();
    }
    if (_delay != appearance.delay) {
      _delay = appearance.delay;
      // Rebase at the edit, keeping the furthest consumed source time so
      // shifting backwards cannot emit the same comments again.
      _feedThrough = math.max(_feedThrough, previous - _delay);
      _epochStart = _feedThrough;
      _pending.clear();
      _feed = comments;
      _resetFeatured();
    }
    if (time == previous) {
      _changeRate(playbackRate);
      return;
    }
    _previous = time;
    _motion += (time - previous) / _rate;
    _changeRate(playbackRate);
    active.removeWhere(
      (row) => row.expired(row.comment.mode == 1 ? _motion : time, viewport),
    );
    final from = _feedThrough, to = time - _delay;
    if (to < from) return;
    final freshness = math.max(.6, playbackRate * .35);
    final changed = !identical(comments, _feed);
    _feed = comments;
    _feedThrough = to;
    final startTime = math.max(changed ? _epochStart : from, to - freshness);
    var start = 0, end = comments.length;
    while (start < end) {
      final middle = (start + end) ~/ 2;
      if (comments[middle].time <= startTime) {
        start = middle + 1;
      } else {
        end = middle;
      }
    }
    for (var i = start; i < math.min(comments.length, start + 300); i++) {
      final row = comments[i];
      if (row.time > to || _pending.length >= 144) break;
      final key = ((row.time * 1000).round(), row.text, row.mode);
      if (!_recent.add(key)) continue;
      if (_recent.length > 512) _recent.remove(_recent.first);
      if (!_enabled(row, appearance)) continue;
      _pending.add((row, time + math.max(4, playbackRate * 2)));
    }
    var admitted = 0;
    final travel = appearance.travel / playbackRate;
    for (
      var probes = math.min(_pending.length, 6);
      probes > 0 && admitted < 3 && active.length < 48;
      probes--
    ) {
      final entry = _pending.removeFirst();
      final row = entry.$1;
      if (entry.$2 < time || !_enabled(row, appearance)) continue;
      final decision = _featured ? _checkFeatured(row, time) : null;
      if (_featured && decision == null) continue;
      final lane = _freeLane(row.mode, lanes, _motion, viewport, travel);
      if (lane == null) {
        _pending.add(entry);
        continue;
      }
      active.add(
        DanmakuFlight(
          row,
          lane,
          row.mode == 1 ? _motion : time,
          measure(row),
          travel,
        ),
      );
      if (decision != null) {
        _rememberFeatured(decision.$1, decision.$2, time);
        if (row.mode == 1) _lastFeaturedRolling = time;
      }
      admitted++;
    }
  }

  void _changeRate(double rate) {
    if (rate == _rate) return;
    final scale = _rate / rate;
    for (final row in active) {
      if (row.comment.mode != 1) continue;
      row.started = _motion - (_motion - row.started) * scale;
      row.travel *= scale;
    }
    _rate = rate;
  }

  bool _enabled(DanmakuComment row, DanmakuAppearance appearance) =>
      switch (row.mode) {
        1 => appearance.scroll,
        4 => appearance.bottom,
        5 => appearance.top,
        _ => false,
      };

  int? _freeLane(
    int mode,
    int lanes,
    double time,
    double width,
    double travel,
  ) {
    final spread = _featured && mode == 1;
    int? fallback;
    for (var i = 0; i < lanes; i++) {
      final lane = mode == 4 ? lanes - i - 1 : i;
      var occupied = false, blocked = false;
      for (final row in active) {
        if (row.lane != lane) continue;
        occupied = true;
        if (mode != 1 ||
            row.comment.mode != 1 ||
            !row.canFollow(time, width, travel)) {
          blocked = true;
          break;
        }
      }
      if (!blocked) {
        if (!spread || !occupied) return lane;
        fallback ??= lane;
      }
      if (fallback != null && i >= 2) break;
    }
    return fallback;
  }

  // Mirrors Windows' admission filter. A lane retry does not count as shown.
  ((String, int), int)? _checkFeatured(DanmakuComment row, double time) {
    final text = row.text.replaceAll(_featuredSeparators, '');
    final key = (text.isEmpty ? row.text.trim() : text.toUpperCase(), row.mode);
    final previous = _repeats[key];
    final repeat = previous != null && time - previous.$1 <= 12
        ? previous.$2 + 1
        : 1;
    if (repeat >= 3 && repeat.isOdd) {
      _rememberFeatured(key, repeat, time);
      return null;
    }
    if (row.mode == 1 &&
        repeat == 1 &&
        time - _lastFeaturedRolling < .40 &&
        active.where((flight) => flight.comment.mode == 1).length >= 3) {
      return null;
    }
    return (key, repeat);
  }

  void _rememberFeatured((String, int) key, int repeat, double time) {
    if (_repeats.length >= 256 && !_repeats.containsKey(key)) _repeats.clear();
    _repeats[key] = (time, repeat);
  }

  void _resetFeatured() {
    _repeats.clear();
    _lastFeaturedRolling = double.negativeInfinity;
  }
}
