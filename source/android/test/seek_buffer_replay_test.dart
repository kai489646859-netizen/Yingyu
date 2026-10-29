import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_buffering.dart';

/// A fluid queue model, not MPV. The fixed native playloop waits for media
/// duration after an underrun/restart; this model evaluates that policy against
/// a fixed arrival schedule. It cannot model decoding, byte caps or real seeks.
({int waits, double waitingSeconds, double firstResume}) replay(
  List<(double, double)> points, {
  required double initialBuffer,
  required double speed,
  required double threshold,
}) {
  var buffer = initialBuffer;
  var paused = buffer < threshold;
  var waits = paused ? 1 : 0;
  var waiting = 0.0;
  var firstResume = paused ? -1.0 : 0.0;
  for (var i = 1; i < points.length; i++) {
    final previous = points[i - 1], next = points[i];
    final duration = next.$1 - previous.$1;
    final supply = (next.$2 - previous.$2) / duration;
    expect(supply, greaterThanOrEqualTo(0));
    // <=10 ms steps; retain the exact interval instead of rounding the clock.
    final steps = (duration * 100).ceil();
    final step = duration / steps;
    for (var n = 0; n < steps; n++) {
      buffer += supply * step;
      if (paused) {
        waiting += step;
        if (buffer >= threshold) {
          paused = false;
          if (firstResume < 0) firstResume = previous.$1 + (n + 1) * step;
        }
      } else {
        buffer -= speed * step;
        if (buffer <= 0) {
          buffer = 0;
          paused = true;
          waits++;
        }
      }
    }
  }
  return (waits: waits, waitingSeconds: waiting, firstResume: firstResume);
}

void main() {
  test('post-seek sampled supply avoids repeated three-times restarts', () {
    final fixture =
        jsonDecode(
              File('test/fixtures/seek-cache-samples.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final points = [
      for (final row
          in fixture['points_seconds_and_added_media_seconds'] as List)
        ((row[0] as num).toDouble(), (row[1] as num).toDouble()),
    ];
    final threshold = double.parse(discBufferOptions(3)['cache-pause-wait']!);
    final initial = (fixture['initial_buffer_seconds'] as num).toDouble();
    final before = replay(
      points,
      initialBuffer: initial,
      speed: 3,
      threshold: 6,
    );
    final after = replay(
      points,
      initialBuffer: initial,
      speed: 3,
      threshold: threshold,
    );
    expect(
      before.waits,
      5,
      reason: 'the fixture must expose the short-cushion problem',
    );
    expect(
      after.waits,
      1,
      reason: 'one initial wait, no further restarts in this sparse replay',
    );
    expect(after.waitingSeconds, lessThanOrEqualTo(before.waitingSeconds + .5));
    expect(after.firstResume, greaterThan(before.firstResume));
    expect(after.firstResume - before.firstResume, lessThan(8));
    Directory('build').createSync(recursive: true);
    File('build/seek-buffer-replay.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'scope': fixture['scope'],
        'threshold_media_seconds': threshold,
        'span_seconds': points.last.$1,
        'before_waits': before.waits,
        'after_waits': after.waits,
        'before_waiting_seconds': before.waitingSeconds,
        'after_waiting_seconds': after.waitingSeconds,
        'first_resume_extra_seconds': after.firstResume - before.firstResume,
        'fixture_source_sha256': fixture['source_sha256'],
        'native_playback': false,
      }),
    );
  });

  test(
    'independent bursty supply absorbs jitter without repeatedly pausing',
    () {
      // Independent fixture: a slow initial burst, a five-second gap, then
      // alternating bursts/gaps and steady supply. Mean supply exceeds 3x.
      const points = [
        (0.0, 0.0),
        (2.0, 10.0),
        (7.0, 10.0),
        (10.0, 50.0),
        (15.0, 50.0),
        (20.0, 90.0),
        (25.0, 90.0),
        (30.0, 140.0),
        (120.0, 410.0),
      ];
      final threshold = double.parse(discBufferOptions(3)['cache-pause-wait']!);
      final before = replay(points, initialBuffer: 0, speed: 3, threshold: 6);
      final after = replay(
        points,
        initialBuffer: 0,
        speed: 3,
        threshold: threshold,
      );
      expect(before.waits, greaterThan(1));
      expect(after.waits, 1);
      expect(after.firstResume, lessThan(10));
      // A genuinely under-supplied source can still stall: no hidden slowdown.
      final slow = replay(
        [(0, 0), (120, 120)],
        initialBuffer: 0,
        speed: 3,
        threshold: threshold,
      );
      expect(slow.waits, greaterThan(1));
    },
  );

  test('cached targets and normal-speed supply keep their existing waits', () {
    const points = [(0.0, 0.0), (3.0, 1.0), (10.0, 33.0), (30.0, 100.0)];
    for (final speed in [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
      final threshold = double.parse(
        discBufferOptions(speed)['cache-pause-wait']!,
      );
      final cached = replay(
        points,
        initialBuffer: 30,
        speed: speed,
        threshold: threshold,
      );
      expect(
        cached.waits,
        0,
        reason: 'a sufficiently cached seek needs no artificial wait',
      );
      if (speed <= 2) {
        final normal = replay(
          points,
          initialBuffer: 0,
          speed: speed,
          threshold: threshold,
        );
        final previous = replay(
          points,
          initialBuffer: 0,
          speed: speed,
          threshold: math.max(1, 2 * speed),
        );
        expect(normal, previous);
      }
    }
  });
}
