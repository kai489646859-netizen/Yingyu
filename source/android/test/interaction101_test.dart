import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/picture_brightness.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'core_test.dart' show syntheticSession;
import 'subtitle_position088_test.dart' show PositionBackend;
import 'player_episode_menu_test.dart' show fonts;
import 'host/player101/old_panels.dart' as old;

class DeferredAdjustments extends PositionBackend
    implements SubtitleDelayBackend, PictureBrightnessBackend {
  Completer<void>? pendingPosition, pendingDelay;
  Duration delay = Duration.zero;
  double gamma = 0;
  int pictureWrites = 0, positionCalls = 0;
  @override
  Future<double> readPictureBrightness({
    required bool Function() allowed,
  }) async => gamma;
  @override
  Future<double> setPictureBrightness(
    double value, {
    required bool Function() allowed,
  }) async {
    if (!allowed()) throw const AppFailure('retired synthetic session');
    pictureWrites++;
    return gamma = value;
  }

  @override
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  }) async {
    positionCalls++;
    await pendingPosition?.future;
    return super.setSubtitlePosition(value, allowed: allowed);
  }

  @override
  Future<Duration> readSubtitleDelay({
    required bool Function() allowed,
  }) async => delay;
  @override
  Future<Duration> setSubtitleDelay(
    Duration value, {
    required bool Function() allowed,
  }) async {
    await pendingDelay?.future;
    if (!allowed()) throw const AppFailure('retired synthetic session');
    return delay = value;
  }
}

void main() {
  late AppStore store;
  late EmbyClient api;
  late PlaybackSession session;
  late DeferredAdjustments backend;
  var created = false;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    api = EmbyClient(
      client: MockClient((_) async => throw StateError('No network')),
    )..session = syntheticSession();
    backend = DeferredAdjustments()..values['sub-pos'] = '50';
    created = false;
  });
  tearDown(() async {
    for (final pending in [backend.pendingPosition, backend.pendingDelay]) {
      if (pending != null && !pending.isCompleted) pending.complete();
    }
    if (created) {
      session.ready = false;
      await session.close();
    }
    api.close();
    store.log.dispose();
    store.dispose();
  });
  Future<void> mount(
    WidgetTester tester,
    String pane, {
    bool oldPosition = false,
  }) async {
    await fonts();
    session =
        PlaybackSession(
            api: api,
            store: store,
            item: MediaItem({'Id': 'synthetic'}),
            backend: backend,
          )
          ..ready = true
          ..loading = false;
    created = true;
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showSurface<void>(
                  context,
                  (_) => oldPosition
                      ? old.SubtitlePositionMenu(
                          session: session,
                          onBack: () {},
                        )
                      : PlayerMenu(
                          session: session,
                          initialPane: pane,
                          fit: BoxFit.contain,
                          onToggle: () {},
                          onSeek: (_) {},
                        ),
                  playerMenu: true,
                  anchor: const Rect.fromLTWH(1000, 700, 40, 40),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('moving subtitle slider applies before the pointer is released', (
    tester,
  ) async {
    await mount(tester, 'subtitlePosition');
    final slider = find.byKey(const Key('subtitle-position-slider'));
    final start = tester.getCenter(slider);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(20, 0));
    await gesture.moveBy(const Offset(55, 0));
    for (var frame = 0; frame < 9; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final movedDuringDrag = backend.writes.isNotEmpty;
    await gesture.up();
    for (var frame = 0; frame < 12; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(backend.writes, isNotEmpty);
    expect(
      movedDuringDrag,
      true,
      reason: 'The real subtitle must move while the pointer remains down',
    );
    expect(backend.values['sid'], 'no');
    expect(backend.writes.toSet(), {'sub-pos'});
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'complete 1.0.0 position panel waits until the same pointer is released',
    (tester) async {
      await mount(tester, 'subtitlePosition', oldPosition: true);
      final slider = find.byKey(const Key('subtitle-position-slider'));
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(20, 0));
      await gesture.moveBy(const Offset(55, 0));
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(backend.writes, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(backend.writes, isNotEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final pane in ['subtitlePosition', 'subtitleDelay']) {
    testWidgets(
      '$pane keeps the same panel rectangle while an operation is pending',
      (tester) async {
        await mount(tester, pane);
        final before = tester.getRect(find.byKey(const Key('surface-panel')));
        final pending = Completer<void>();
        if (pane == 'subtitlePosition') {
          backend.pendingPosition = pending;
        } else {
          backend.pendingDelay = pending;
        }
        await tester.tap(
          find.text(pane == 'subtitlePosition' ? '上移 5%' : '延后 0.1 秒'),
        );
        await tester.pump();
        final during = tester.getRect(find.byKey(const Key('surface-panel')));
        pending.complete();
        for (var frame = 0; frame < 12; frame++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        final after = tester.getRect(find.byKey(const Key('surface-panel')));
        expect(
          during,
          before,
          reason: 'Busy feedback must not flash a differently sized panel',
        );
        expect(after, before);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'live slider coalesces pending values and the latest thumb never jumps back',
    (tester) async {
      await mount(tester, 'subtitlePosition');
      final gate = backend.pendingPosition = Completer<void>();
      void move(double value) => tester
          .widget<CupertinoSlider>(
            find.byKey(const Key('subtitle-position-slider')),
          )
          .onChanged!(value);
      move(60);
      await tester.pump();
      move(70);
      move(80);
      move(90);
      await tester.pump();
      expect(backend.positionCalls, 1);
      expect(
        tester
            .widget<CupertinoSlider>(
              find.byKey(const Key('subtitle-position-slider')),
            )
            .value,
        90,
      );
      gate.complete();
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(backend.positionCalls, 2);
      expect(double.parse(backend.values['sub-pos']!), 10);
      expect(
        tester
            .widget<CupertinoSlider>(
              find.byKey(const Key('subtitle-position-slider')),
            )
            .value,
        90,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('closing position panel discards unsent drag values', (
    tester,
  ) async {
    await mount(tester, 'subtitlePosition');
    final gate = backend.pendingPosition = Completer<void>();
    final move = tester
        .widget<CupertinoSlider>(
          find.byKey(const Key('subtitle-position-slider')),
        )
        .onChanged!;
    move(60);
    await tester.pump();
    move(90);
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(backend.positionCalls, 1);
  });
  testWidgets(
    'picture menu leaves original playback untouched until explicit adjustment',
    (tester) async {
      await mount(tester, 'pictureBrightness');
      expect(backend.pictureWrites, 0);
      expect(find.text('原始画面'), findsOneWidget);
      await tester.tap(find.text('轻度提亮'));
      await tester.pumpAndSettle();
      expect(backend.gamma, 5);
      await tester.tap(find.text('原始画面'));
      await tester.pumpAndSettle();
      expect(backend.gamma, 0);
      expect(backend.writes, isEmpty);
      expect(session.error, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'hidden foreground rate is immediately available whenever controls reopen',
    (tester) async {
      var full = 0, rates = 0;
      final controller = PlayerStatusController(
        read: () async {
          full++;
          return {
            'rxBytesPerSecond': 2048,
            'network': 'wifi',
            'batteryPercent': 80,
          };
        },
        readRate: () async {
          rates++;
          return {'rxBytesPerSecond': 4096};
        },
      );
      controller.setKeepRateWarm(true);
      controller.setActive(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      controller.setActive(false);
      await tester.pump();
      final hiddenFull = full;
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(full, hiddenFull);
      expect(rates, greaterThan(5));
      for (var i = 0; i < 3; i++) {
        controller.setActive(true);
        expect(controller.value.rateText, '4.0 KB/s');
        await tester.pump();
        controller.setActive(false);
        await tester.pump();
      }
      controller.setActive(false);
      controller.setKeepRateWarm(false);
      final stopped = full + rates;
      await tester.pump(const Duration(seconds: 2));
      expect(full + rates, stopped);
      controller.dispose();
    },
  );
  testWidgets('visible receive rate refreshes again each second', (
    tester,
  ) async {
    var calls = 0;
    final controller = PlayerStatusController(
      read: () async {
        calls++;
        return {'rxBytesPerSecond': calls * 1024, 'network': 'wifi'};
      },
    );
    controller.setActive(true);
    await tester.pump();
    final first = calls;
    await tester.pump(const Duration(milliseconds: 550));
    expect(calls, first);
    await tester.pump(const Duration(milliseconds: 500));
    final second = calls;
    controller.dispose();
    await tester.pump();
    expect(second, greaterThan(first));
  });
}
