import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/danmaku_flights.dart';
import 'package:yingyu/playback/danmaku_overlay.dart';
import 'package:yingyu/playback/danmaku_preferences.dart';
import 'package:yingyu/playback/danmaku_sources.dart';
import 'package:yingyu/playback/session.dart';

import 'core_test.dart' show syntheticSession;
import 'playback_test.dart' show FakeBackend;

class _ClockSession extends PlaybackSession {
  _ClockSession(AppStore store, FakeBackend backend)
    : super(
        api: EmbyClient()..session = syntheticSession(),
        store: store,
        item: MediaItem({'Id': 'synthetic'}),
        backend: backend,
      );

  @override
  Duration position = Duration.zero;

  void advance(int ms) {
    position = Duration(milliseconds: ms);
    notifyListeners();
  }
}

void main() {
  test(
    'speed edits keep the current pace and reserve space for faster rows',
    () {
      final flights = DanmakuFlights();
      const rows = [
        DanmakuComment(.1, '在途', 1, 0xffffff),
        DanmakuComment(1.7, '加速后', 1, 0xffffff),
      ];
      void step(double time, double travel) => flights.advance(
        comments: rows,
        time: time,
        viewport: 800,
        lanes: 2,
        appearance: defaultDanmakuAppearance.update(travel: travel),
        measure: (_) => 100,
      );
      step(0, 9);
      step(.2, 9);
      final active = flights.active.single;
      step(1.0, 9);
      step(1.8, 4);
      expect(flights.active.first, same(active));
      expect(active.x(1.8, 800), closeTo(800 - 800 * 1.6 / 9, .001));
      expect(flights.active.last.lane, isNot(active.lane));
      expect(flights.active.last.travel, 4);
      expect(flights.active.last.x(1.8, 800), 800);
    },
  );

  test('time offset skips crossed history and never replays consumed rows', () {
    final flights = DanmakuFlights();
    const rows = [
      DanmakuComment(.1, '已入场', 5, 0xffffff),
      DanmakuComment(1.6, '提前后跨过的旧弹幕', 5, 0xffffff),
      DanmakuComment(2.2, '下一条', 5, 0xffffff),
    ];
    void step(double time, double delay) => flights.advance(
      comments: rows,
      time: time,
      viewport: 800,
      lanes: 8,
      appearance: defaultDanmakuAppearance.update(delay: delay),
      measure: (_) => 100,
    );
    step(0, 0);
    step(.2, 0);
    step(.8, 0);
    step(.8, -1);
    step(1.3, -1);
    step(1.3, 1.5);
    for (final time in [2.0, 2.6, 3.2, 3.8]) {
      step(time, 1.5);
    }
    expect(flights.active.map((row) => row.comment), [rows[0], rows[2]]);
  });

  testWidgets('live appearance edits keep the current rolling comment', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final backend = FakeBackend();
    final store = AppStore(await SharedPreferences.getInstance());
    final session = _ClockSession(store, backend);
    final controller = DanmakuOverlayController();
    final status = ValueNotifier('');
    var appearance = defaultDanmakuAppearance;
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            refresh = setState;
            return SizedBox.expand(
              child: DanmakuOverlay(
                session: session,
                identity: null,
                compatible: null,
                status: status,
                createSource: DanmakuSources.new,
                preferences: DanmakuPreferences(
                  automatic: false,
                  appearance: appearance,
                ),
                controller: controller,
              ),
            );
          },
        ),
      ),
    );
    await backend.play();
    controller.selectLocal(
      session,
      DanmakuTrack('合成', [
        (
          start: 0,
          end: 120,
          load: () async => const [
            DanmakuComment(.1, '第一条合成弹幕', 1, 0xffffff),
            DanmakuComment(.1, '第二条合成弹幕', 1, 0xffffff),
            DanmakuComment(.1, '第三条合成弹幕', 1, 0xffffff),
            DanmakuComment(.5, '合成弹幕', 1, 0xffffff),
          ],
        ),
      ]),
    );
    await tester.pump();
    for (final time in [200, 400, 600, 900]) {
      session.advance(time);
      await tester.pump();
    }
    await backend.pause();
    session.advance(900);
    await tester.pump();
    final surface = find.descendant(
      of: find.byType(DanmakuOverlay),
      matching: find.byType(CustomPaint),
    );
    final x = isA<Offset>().having(
      (point) => point.dx,
      'x',
      inInclusiveRange(772, 774),
    );
    void visible() => expect(
      surface,
      paints
        ..paragraph()
        ..paragraph()
        ..paragraph()
        ..paragraph(offset: x),
    );
    visible();
    refresh(() => appearance = appearance.update(area: .20));
    await tester.pump();
    expect(
      surface,
      paints
        ..paragraph()
        ..paragraph()
        ..paragraph()
        ..paragraph(
          offset: allOf(
            x,
            isA<Offset>().having((point) => point.dy, 'y', greaterThan(108)),
          ),
        ),
    );
    refresh(() => appearance = defaultDanmakuAppearance);
    await tester.pump();
    for (final next in [
      appearance.update(area: .25),
      appearance.update(fontSize: 33, adaptive: false),
      appearance.update(travel: 4, opacity: .4, background: true),
      appearance.update(delay: 1, featured: true),
      defaultDanmakuAppearance,
    ]) {
      refresh(() => appearance = next);
      await tester.pump();
      visible();
    }
    refresh(() => appearance = appearance.update(scroll: false));
    await tester.pump();
    expect(surface, isNot(paints..paragraph()));
    refresh(() => appearance = appearance.update(scroll: true));
    await tester.pump();
    visible();
    controller.retry();
    await tester.pump();
    visible();
    controller.clear();
    await tester.pump();
    expect(surface, isNot(paints..paragraph()));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 300));
    controller.dispose();
    status.dispose();
    await backend.dispose();
  });
}
