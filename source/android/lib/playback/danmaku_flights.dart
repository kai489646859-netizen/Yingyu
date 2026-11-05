import 'dart:math' as math;

import 'danmaku_preferences.dart';
import 'danmaku_sources.dart';

class DanmakuFlight {
  DanmakuFlight(this.comment, this.lane, this.started, this.width, this.travel);
  final DanmakuComment comment;
  final int lane;
  final double started, travel;
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
}

/// Owns the lifetime of visible comments. The incoming feed may be replaced
/// after any network segment without reassigning already visible lanes.
class DanmakuFlights {
  final active = <DanmakuFlight>[];
  final _repeats = <(String, int), (double, bool)>{};
  double? _previous;
  double _feedThrough = 0, _delay = 0;
  bool _featured = false;

  void clear() {
    active.clear();
    _repeats.clear();
    _previous = null;
  }

  void advance({
    required List<DanmakuComment> comments,
    required double time,
    required double viewport,
    required int lanes,
    required DanmakuAppearance appearance,
    required double Function(DanmakuComment) measure,
  }) {
    final previous = _previous;
    if (previous == null || time < previous || time - previous > 1) {
      clear();
      _previous = time;
      _delay = appearance.delay;
      _feedThrough = time - _delay;
      return;
    }
    if (_featured != appearance.featured) {
      _featured = appearance.featured;
      _repeats.clear();
    }
    if (_delay != appearance.delay) {
      _delay = appearance.delay;
      // Rebase at the edit, keeping the furthest consumed source time so
      // shifting backwards cannot emit the same comments again.
      _feedThrough = math.max(_feedThrough, previous - _delay);
      _repeats.clear();
    }
    if (time == previous) return;
    _previous = time;
    active.removeWhere((row) => row.expired(time, viewport));
    final from = _feedThrough, to = time - _delay;
    if (to <= from || lanes == 0) {
      _feedThrough = math.max(from, to);
      return;
    }
    _feedThrough = to;
    var start = 0, end = comments.length;
    while (start < end) {
      final middle = (start + end) ~/ 2;
      if (comments[middle].time <= from) {
        start = middle + 1;
      } else {
        end = middle;
      }
    }
    var admitted = 0;
    for (var i = start; i < math.min(comments.length, start + 300); i++) {
      final row = comments[i];
      if (row.time > to || admitted >= 3 || active.length >= 48) break;
      final enabled = switch (row.mode) {
        1 => appearance.scroll,
        4 => appearance.bottom,
        5 => appearance.top,
        _ => false,
      };
      if (!enabled || (_featured && _skipRepeat(row, time, viewport))) {
        continue;
      }
      final lane = _freeLane(
        row.mode,
        lanes,
        time,
        viewport,
        appearance.travel,
      );
      if (lane == null) continue;
      active.add(
        DanmakuFlight(row, lane, time, measure(row), appearance.travel),
      );
      admitted++;
    }
  }

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

  bool _skipRepeat(DanmakuComment row, double time, double width) {
    final key = (row.text.trim(), row.mode);
    final previous = _repeats[key];
    final drop =
        previous != null && row.time - previous.$1 <= 12 && previous.$2;
    if (_repeats.length >= 256 && !_repeats.containsKey(key)) _repeats.clear();
    _repeats[key] = (row.time, !drop);
    if (!drop || row.mode != 1) return drop;
    var visibleLanes = 0;
    for (final flight in active) {
      if (flight.comment.mode != 1 || flight.x(time, width) >= width) continue;
      visibleLanes |= 1 << flight.lane;
      if ((visibleLanes & (visibleLanes - 1)) != 0) return true;
    }
    return false;
  }
}
