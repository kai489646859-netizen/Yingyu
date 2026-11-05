import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/danmaku_clock.dart';
import 'package:yingyu/playback/danmaku_flights.dart';
import 'package:yingyu/playback/danmaku_preferences.dart';
import 'package:yingyu/playback/danmaku_sources.dart';

void main() {
  test(
    'featured spreads new rows and shrinking the area only limits admission',
    () {
      final flights = DanmakuFlights();
      const rows = [
        DanmakuComment(.1, '先入场', 1, 0xffffff),
        DanmakuComment(.4, '精选优先空轨', 1, 0xffffff),
        DanmakuComment(.8, '缩小区域后入场', 1, 0xffffff),
      ];
      void step(double time, int lanes, bool featured) => flights.advance(
        comments: rows,
        time: time,
        viewport: 800,
        lanes: lanes,
        appearance: defaultDanmakuAppearance.update(
          travel: 4,
          featured: featured,
        ),
        measure: (_) => 30,
      );
      step(0, 6, false);
      step(.2, 6, false);
      step(.5, 6, true);
      expect(flights.active.map((row) => row.lane), [0, 1]);
      final outside = flights.active.last;
      step(.9, 1, true);
      expect(flights.active.map((row) => row.lane), [0, 1, 0]);
      expect(flights.active[1], same(outside));
      expect(outside.x(.9, 800), lessThan(800));
    },
  );

  for (final speed in [2.0, 3.0]) {
    test('${speed}x sparse and delayed samples keep advancing smoothly', () {
      final clock = DanmakuClock();
      var position = 30.0;
      for (var frame = 0; frame <= 120; frame++) {
        final now = frame / 60;
        if (frame % 15 == 0) position = 30 + now * speed;
        if (frame == 32) position -= 1.15;
        final before = clock.value;
        final reset = clock.update(
          now: now,
          position: position,
          speed: speed,
          running: true,
          revision: 1,
        );
        if (frame == 0) continue;
        expect(reset, isFalse, reason: 'frame $frame');
        expect(
          clock.value - before,
          inInclusiveRange(speed / 60 * .79, speed / 60 * 1.21),
          reason: 'frame $frame',
        );
      }
      expect(clock.value, closeTo(30 + 2 * speed, .18));
    });
  }

  test('a delayed position report does not reset a high-speed flight', () {
    final clock = DanmakuClock();
    bool step(double now, double position, int revision) => clock.update(
      now: now,
      position: position,
      speed: 3,
      running: true,
      revision: revision,
    );
    expect(step(0, 80, 1), isTrue);
    for (var frame = 1; frame <= 30; frame++) {
      expect(step(frame / 60, 80 + frame / 20, 1), isFalse);
    }
    final before = clock.value;
    expect(step(.52, 80.2, 1), isFalse);
    expect(clock.value, greaterThan(before));
    expect(step(.53, 12, 2), isTrue);
    expect(clock.value, 12);
  });

  test('rate changes are continuous through 1x, 2x, 3x, 2x and 1x', () {
    final clock = DanmakuClock();
    var position = 10.0;
    var previousRate = 1.0;
    for (var frame = 0; frame < 360; frame++) {
      final rate = [1.0, 2.0, 3.0, 2.0, 1.0, 1.0][frame ~/ 60];
      if (frame > 0) position += previousRate / 60;
      final before = clock.value;
      final reset = clock.update(
        now: frame / 60,
        position: position,
        speed: rate,
        running: true,
        revision: 1,
      );
      if (frame > 0) {
        expect(reset, isFalse);
        final movement = clock.value - before;
        expect(
          movement,
          inInclusiveRange(previousRate * .79 / 60, previousRate * 1.21 / 60),
        );
        if (frame < 60 || frame > 325) {
          expect(clock.value, closeTo(position, .03));
        }
      }
      previousRate = rate;
    }
  });

  test('stale samples, pause and buffering freeze, then a seek reanchors', () {
    final clock = DanmakuClock();
    bool step(
      double now,
      double position, {
      bool running = true,
      int revision = 1,
      bool seeking = false,
    }) => clock.update(
      now: now,
      position: position,
      speed: 3,
      running: running,
      revision: revision,
      seeking: seeking,
    );
    step(0, 30);
    for (var frame = 1; frame <= 48; frame++) {
      step(frame / 60, 30);
    }
    final stalled = clock.value;
    step(2, 30);
    expect(clock.value, stalled);
    step(2.02, 36);
    expect(clock.value, inInclusiveRange(stalled, stalled + .08));
    step(2.03, 36, running: false);
    final paused = clock.value;
    step(5, 36.03, running: false);
    expect(clock.value, paused);
    step(5.01, 36.03);
    expect(clock.value, paused);
    expect(step(5.02, 8, running: false, revision: 2, seeking: true), isTrue);
    expect(clock.value, 8);
    expect(step(5.03, 8.2, revision: 2), isTrue);
    expect(clock.value, 8.2);
  });
}
