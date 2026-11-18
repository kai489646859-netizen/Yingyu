import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/danmaku_flights.dart';
import 'package:yingyu/playback/danmaku_preferences.dart';
import 'package:yingyu/playback/danmaku_sources.dart';

void main() {
  List<DanmakuComment> play(
    List<DanmakuComment> rows,
    double tick, {
    bool featured = true,
    int Function(double)? lanes,
  }) {
    final flights = DanmakuFlights();
    final shown = <DanmakuComment>{};
    for (var time = 0.0; time <= rows.length * tick + tick; time += tick) {
      flights.advance(
        comments: rows,
        time: time,
        viewport: 800,
        lanes: lanes?.call(time) ?? 12,
        appearance: defaultDanmakuAppearance.update(featured: featured),
        measure: (_) => 30,
      );
      shown.addAll(flights.active.map((flight) => flight.comment));
    }
    return shown.toList();
  }

  test('Windows repeat sequence keeps the first two normalized messages', () {
    final rows = List.generate(
      20,
      (i) => DanmakuComment(
        i * .5 + .25,
        i.isEven ? 'Go　好 看！' : 'go好看',
        1,
        0xffffff,
      ),
    );
    expect(play(rows, .5, featured: false), rows);
    expect(play(rows, .5), [
      rows[0],
      rows[1],
      for (var i = 3; i < rows.length; i += 2) rows[i],
    ]);
  });

  test('Windows density rule thins rolling bursts and retains sparse rows', () {
    List<DanmakuComment> rowsAt(double tick) => List.generate(
      20,
      (i) => DanmakuComment(i * tick + tick / 2, '评论 $i', 1, 0xffffff),
    );
    final burst = rowsAt(.125);
    expect(play(burst, .125, featured: false), burst);
    expect(play(burst, .125), [
      for (final i in [0, 1, 2, 6, 10, 14, 18]) burst[i],
    ]);
    final sparse = rowsAt(.5);
    expect(play(sparse, .5), sparse);
  });

  test('Windows admission counts a queued repeat only when a lane opens', () {
    const rows = [
      DanmakuComment(.125, '很好', 5, 0xffffff),
      DanmakuComment(.375, '很好！', 5, 0xffffff),
      DanmakuComment(.625, '很 好', 5, 0xffffff),
    ];
    expect(play(rows, .25, lanes: (time) => time < 1 ? 1 : 3), rows.take(2));
  });
}
