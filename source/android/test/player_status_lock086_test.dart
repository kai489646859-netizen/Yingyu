import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'offline_settle.dart' show settleOffline;
import 'playback_test.dart' show FakeBackend;

final _fixedTime = DateTime(2026, 10, 16, 5, 25).millisecondsSinceEpoch;
Map<String, Object?> _status() => {
  'wallTimeMs': _fixedTime,
  'rxBytesPerSecond': 1572864.0,
  'network': 'wifi',
  'batteryPercent': 53,
  'charging': false,
};

class _LockBackend extends FakeBackend {
  final rates = <double>[];
  final seeks = <Duration>[];
  int pauses = 0;
  bool rejectRestore = false;
  @override
  Future<void> rate(double value) async {
    rates.add(value);
    if (rejectRestore && value == 1) {
      throw StateError('synthetic restore rejected');
    }
    await super.rate(value);
  }

  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    await super.seek(value);
  }

  @override
  Future<void> pause() async {
    pauses++;
    await super.pause();
  }
}

class _Fixture {
  late final AppStore store;
  late final EmbyClient api;
  final backends = <_LockBackend>[];
  final sessions = <PlaybackSession>[];
  final deviceCalls = <MethodCall>[];
  final reports = <String>[];
  final navigator = GlobalKey<NavigatorState>();
  final capture = GlobalKey();
  var statusSamples = 0;
  var rateSamples = 0, statusResets = 0;
  bool firstRate = true;
  bool statusFails = false;
  Map<String, Object?> values = _status();
  _LockBackend get backend => backends.last;
  PlaybackSession get session => sessions.last;

  Future<void> mount(
    WidgetTester tester, {
    bool delayReady = false,
    Size size = const Size(900, 500),
    bool realisticRateReset = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.display.size = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.display.resetSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(Device.channel, (call) async {
      deviceCalls.add(call);
      if (call.method == 'focus') return true;
      if (call.method == 'levels') return {'brightness': .5, 'volume': .5};
      return null;
    });
    messenger.setMockMethodCallHandler(PlayerStatusController.channel, (
      call,
    ) async {
      if (call.method == 'reset') {
        statusResets++;
        firstRate = true;
        return null;
      }
      if (call.method == 'rate') {
        rateSamples++;
        final result = {
          'rxBytesPerSecond': realisticRateReset && firstRate
              ? null
              : 1572864.0,
        };
        firstRate = false;
        return result;
      }
      if (call.method != 'sample') return null;
      statusSamples++;
      if (statusFails) throw PlatformException(code: 'synthetic');
      final result = {...values};
      if (realisticRateReset && firstRate) result['rxBytesPerSecond'] = null;
      firstRate = false;
      return result;
    });
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (request.url.path.contains('Sessions/Playing')) {
          reports.add(request.url.path);
          return response('', 204);
        }
        return response(
          '{"Id":"movie","Name":"合成影片","Type":"Movie","RunTimeTicks":54000000000}',
          200,
        );
      }),
    )..session = syntheticSession();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('returned')),
        ),
      ),
    );
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) => PlayerPage(
          createSession: () {
            final backend = _LockBackend();
            if (!delayReady) backend.gate.complete();
            backends.add(backend);
            final session = PlaybackSession(
              api: api,
              store: store,
              item: MediaItem({'Id': 'movie', 'Name': '合成影片'}),
              backend: backend,
            );
            sessions.add(session);
            return session;
          },
        ),
      ),
    );
    if (delayReady) {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(backend.opened.isCompleted, isTrue);
      expect(session.loading, isTrue);
      expect(session.ready, isFalse);
    } else {
      await tester.pumpAndSettle();
      expect(session.ready, isTrue);
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    for (final backend in backends) {
      await tester.runAsync(backend.dispose);
    }
    api.close();
    await store.log.flush();
    store.log.dispose();
    store.dispose();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      Device.channel,
      null,
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      PlayerStatusController.channel,
      null,
    );
  }

  Future<void> lock(WidgetTester tester) async {
    await tester.tap(find.byTooltip('锁定屏幕'));
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester, String name) async {
    final boundary =
        capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/play105/previews/loading-$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'loading permits local brightness and volume until touch is locked',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester, delayReady: true);
      final brightnessDrag = await tester.startGesture(const Offset(200, 340));
      await brightnessDrag.moveBy(const Offset(0, -30));
      await brightnessDrag.moveBy(const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 200));
      await f.preview(tester, 'brightness');
      await brightnessDrag.up();
      final volumeDrag = await tester.startGesture(const Offset(700, 340));
      await volumeDrag.moveBy(const Offset(0, -30));
      await volumeDrag.moveBy(const Offset(0, -120));
      await tester.pump(const Duration(milliseconds: 200));
      await f.preview(tester, 'volume');
      await volumeDrag.up();
      final changes = f.deviceCalls
          .where((c) => c.method == 'brightness' || c.method == 'volume')
          .toList();
      expect(changes.where((c) => c.method == 'brightness'), isNotEmpty);
      expect(changes.where((c) => c.method == 'volume'), isNotEmpty);
      expect(f.session.loading, isTrue);
      expect(f.backend.seeks, isEmpty);
      expect(f.backend.rates, isEmpty);
      await tester.tap(find.byTooltip('锁定屏幕'));
      // Loading intentionally keeps the spinner animating.
      await tester.pump(const Duration(milliseconds: 200));
      final count = f.deviceCalls.length;
      await tester.dragFrom(const Offset(200, 340), const Offset(0, -150));
      await tester.dragFrom(const Offset(700, 340), const Offset(0, -150));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        f.deviceCalls
            .skip(count)
            .where((c) => c.method == 'brightness' || c.method == 'volume'),
        isEmpty,
      );
      f.backend.gate.complete();
      await tester.pumpAndSettle();
      await f.finish(tester);
    },
  );
  test(
    'status unknown values remain placeholders and real zero remains measured zero',
    () {
      final unknown = PlayerStatusData.fromMap({
        'rxBytesPerSecond': -1,
        'batteryPercent': -1,
      });
      expect(unknown.rateText, '— KB/s');
      expect(unknown.batteryPercent, isNull);
      expect(unknown.networkText, '—');
      expect(
        PlayerStatusData.fromMap({'rxBytesPerSecond': 0}).rateText,
        '0 B/s',
      );
    },
  );
  test('status formats real app receive rate clock and connection kind', () {
    final data = PlayerStatusData.fromMap(_status());
    expect(data.timeText, '05:25');
    expect(data.rateText, '1.5 MB/s');
    expect(data.networkText, 'Wi-Fi');
    expect(data.batteryPercent, 53);
    expect(
      PlayerStatusData.fromMap({'rxBytesPerSecond': 1536}).rateText,
      '1.5 KB/s',
    );
    expect(
      PlayerStatusData.fromMap({'network': 'disconnected'}).networkText,
      '断开',
    );
  });
  testWidgets(
    'status controller polls only while active and drops hidden late responses',
    (tester) async {
      var calls = 0;
      Completer<Map<Object?, Object?>?>? gate;
      final controller = PlayerStatusController(
        read: () async {
          calls++;
          return gate == null ? _status() : gate.future;
        },
        readRate: () async => {'rxBytesPerSecond': 1024},
      );
      await tester.pump(const Duration(seconds: 2));
      expect(calls, 0);
      controller.setActive(true);
      await tester.pump();
      expect(calls, 1);
      expect(controller.value.network, 'wifi');
      await tester.pump(const Duration(seconds: 1));
      expect(calls, 2);
      gate = Completer<Map<Object?, Object?>?>();
      await tester.pump(const Duration(seconds: 1));
      controller.setActive(false);
      gate.complete({'network': 'cellular'});
      await tester.pump();
      expect(controller.value.network, 'wifi');
      final stopped = calls;
      await tester.pump(const Duration(seconds: 5));
      expect(calls, stopped);
      controller.dispose();
    },
  );
  testWidgets(
    'status controller query failure and late dispose remain harmless',
    (tester) async {
      final gate = Completer<Map<Object?, Object?>?>();
      final controller = PlayerStatusController(read: () => gate.future);
      controller.setActive(true);
      controller.dispose();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      gate.complete(_status());
      await tester.pump();
      final failed = PlayerStatusController(
        read: () async => throw StateError('synthetic'),
      );
      failed.setActive(true);
      await tester.pump();
      expect(failed.value.rxBytesPerSecond, isNull);
      expect(failed.value.networkText, '—');
      failed.dispose();
    },
  );

  testWidgets(
    'loading at zero can lock touch and a real opening failure reveals controls',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester, delayReady: true);
      expect(find.byTooltip('锁定屏幕').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('锁定屏幕'));
      await tester.pump(const Duration(milliseconds: 300));
      final dynamic state = tester.state(find.byType(PlayerPage));
      expect(state.locked, isTrue);
      expect(f.backend.seeks, isEmpty);
      f.backend.gate.completeError(StateError('synthetic opening failure'));
      await tester.pumpAndSettle();
      expect(state.locked, isFalse);
      expect(find.textContaining('synthetic opening failure'), findsOneWidget);
      expect(find.byTooltip('退出播放').hitTestable(), findsOneWidget);
      await f.finish(tester);
    },
  );

  testWidgets(
    'player status and unlocked lock key hide together after five seconds',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      expect(find.text('05:25').hitTestable(), findsOneWidget);
      expect(find.byTooltip('锁定屏幕').hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 5300));
      await tester.pumpAndSettle();
      expect(find.text('05:25').hitTestable(), findsNothing);
      expect(find.byTooltip('锁定屏幕').hitTestable(), findsNothing);
      final samples = f.statusSamples;
      await tester.pump(const Duration(seconds: 2));
      expect(f.statusSamples, samples);
      await tester.tapAt(const Offset(450, 250));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('05:25').hitTestable(), findsOneWidget);
      expect(f.statusSamples, greaterThan(samples));
      await f.finish(tester);
    },
  );
  testWidgets(
    'tablet controls reopen with the live receive rate without resetting native counters',
    (tester) async {
      final f = _Fixture();
      await f.mount(
        tester,
        size: const Size(1280, 800),
        realisticRateReset: true,
      );
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      final resets = f.statusResets,
          full = f.statusSamples,
          hiddenRates = f.rateSamples;
      expect(
        find.byKey(const Key('player-receive-rate')).hitTestable(),
        findsNothing,
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(f.statusSamples, full);
      expect(f.rateSamples, greaterThan(hiddenRates));
      for (var i = 0; i < 3; i++) {
        await tester.tapAt(const Offset(640, 400));
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('1.5 MB/s').hitTestable(), findsOneWidget);
        expect(find.text('— KB/s').hitTestable(), findsNothing);
        expect(f.statusResets, resets);
        await tester.tapAt(const Offset(640, 400));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(milliseconds: 500));
      }
      await f.finish(tester);
    },
  );

  testWidgets(
    'locked player ignores double tap seek levels and temporary speed then unlocks normally',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.lock(tester);
      final seeks = f.backend.seeks.length,
          pauses = f.backend.pauses,
          plays = f.backend.plays;
      final rates = List<double>.of(f.backend.rates);
      final levels = f.deviceCalls
          .where((c) => c.method == 'brightness' || c.method == 'volume')
          .length;
      await tester.tapAt(const Offset(450, 250));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(450, 250));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.dragFrom(const Offset(300, 250), const Offset(180, 0));
      await tester.dragFrom(const Offset(200, 250), const Offset(0, -100));
      await tester.dragFrom(const Offset(650, 250), const Offset(0, -100));
      final hold = await tester.startGesture(const Offset(450, 250));
      await tester.pump(const Duration(milliseconds: 700));
      await hold.up();
      await tester.pump();
      expect(f.backend.seeks.length, seeks);
      expect(f.backend.pauses, pauses);
      expect(f.backend.plays, plays);
      expect(f.backend.rates, rates);
      expect(
        f.deviceCalls
            .where((c) => c.method == 'brightness' || c.method == 'volume')
            .length,
        levels,
      );
      await tester.tapAt(const Offset(450, 250));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsNothing);
      await tester.tapAt(const Offset(450, 250));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('解锁屏幕'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('播放器菜单').hitTestable(), findsOneWidget);
      await tester.dragFrom(const Offset(300, 250), const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(f.backend.seeks.length, seeks + 1);
      await f.finish(tester);
    },
  );

  testWidgets(
    'locked taps hide and reveal the key without leaving a stale auto-hide timer',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.session.toggle();
      await tester.pumpAndSettle();
      await f.lock(tester);
      final dynamic state = tester.state(find.byType(PlayerPage));
      final samples = f.statusSamples;
      final pauses = f.backend.pauses, plays = f.backend.plays;
      await tester.tapAt(const Offset(450, 250));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsNothing);
      expect(state.locked, isTrue);
      expect(state.hideTimer.isActive, isFalse);
      await tester.pump(const Duration(seconds: 2));
      await tester.tapAt(const Offset(450, 250));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1400));
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsOneWidget);
      expect(find.byTooltip('播放器菜单').hitTestable(), findsNothing);
      expect(f.statusSamples, samples);
      expect(f.backend.pauses, pauses);
      expect(f.backend.plays, plays);
      await tester.pump(const Duration(milliseconds: 3800));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsNothing);
      await f.finish(tester);
    },
  );

  testWidgets(
    'locked tap reveals only unlock key and it hides after five seconds even paused',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.session.toggle();
      await tester.pumpAndSettle();
      await f.lock(tester);
      await tester.pump(const Duration(milliseconds: 5300));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsNothing);
      final samples = f.statusSamples;
      await tester.tapAt(const Offset(450, 250));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsOneWidget);
      expect(find.byTooltip('播放器菜单').hitTestable(), findsNothing);
      expect(find.text('05:25').hitTestable(), findsNothing);
      await tester.pump(const Duration(milliseconds: 5300));
      await tester.pumpAndSettle();
      expect(find.byTooltip('解锁屏幕').hitTestable(), findsNothing);
      expect(f.statusSamples, samples);
      await f.finish(tester);
    },
  );

  testWidgets('locking during an active scrub discards the pending target', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    final before = f.backend.seeks.length;
    final gesture = await tester.startGesture(const Offset(300, 250));
    await gesture.moveBy(const Offset(150, 0));
    await tester.pump();
    final dynamic state = tester.state(find.byType(PlayerPage));
    state.toggleLock();
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(f.backend.seeks.length, before);
    expect(state.scrub, isNull);
    await f.finish(tester);
  });

  testWidgets(
    'two pointer slider drag cannot seek after the other pointer locks',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final before = f.backend.seeks.length;
      final slider = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('playback-timeline'))),
        pointer: 1,
      );
      await slider.moveBy(const Offset(45, 0));
      await tester.pump();
      final lock = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('player-screen-lock'))),
        pointer: 2,
      );
      await lock.up();
      await tester.pump();
      await slider.moveBy(const Offset(45, 0));
      await slider.up();
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      expect(state.locked, isTrue);
      expect(f.backend.seeks.length, before);
      await f.finish(tester);
    },
  );

  testWidgets(
    'touch lock blocks the existing manual skip overlay without changing its rule',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.store.personal.setSkipRule(
        f.session.account,
        f.session.currentMetadata,
        SkipScope.item,
        const SkipRule(
          intro: IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
        ),
        const Duration(minutes: 90),
      );
      await f.backend.seek(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(find.text('跳过片头').hitTestable(), findsOneWidget);
      final target = tester.getCenter(find.text('跳过片头'));
      final before = f.backend.seeks.length;
      await f.lock(tester);
      expect(find.text('跳过片头').hitTestable(), findsNothing);
      await tester.tapAt(target);
      await tester.pumpAndSettle();
      expect(f.backend.seeks.length, before);
      expect(
        f.store.personal.resolveSkipRule(
          f.session.account,
          f.session.currentMetadata,
        ),
        isNotNull,
      );
      await f.finish(tester);
    },
  );

  testWidgets(
    'locking ends a temporary speed hold without changing selected speed',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final hold = await tester.startGesture(const Offset(450, 250));
      await tester.pump(const Duration(milliseconds: 700));
      expect(f.session.holdingSpeed, isTrue);
      expect(f.backend.speed, 3);
      final dynamic state = tester.state(find.byType(PlayerPage));
      state.toggleLock();
      await tester.pumpAndSettle();
      await hold.up();
      await tester.pumpAndSettle();
      expect(f.session.holdingSpeed, isFalse);
      expect(f.backend.speed, 1);
      expect(state.locked, isTrue);
      await f.finish(tester);
    },
  );

  testWidgets(
    'a skip button already pressed by another finger is cancelled when locking',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.store.personal.setSkipRule(
        f.session.account,
        f.session.currentMetadata,
        SkipScope.item,
        const SkipRule(
          intro: IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
        ),
        const Duration(minutes: 90),
      );
      await f.backend.seek(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      final before = f.backend.seeks.length;
      final skip = await tester.startGesture(
        tester.getCenter(find.text('跳过片头')),
        pointer: 1,
      );
      final lock = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('player-screen-lock'))),
        pointer: 2,
      );
      await lock.up();
      await tester.pump();
      await skip.up();
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      expect(state.locked, isTrue);
      expect(f.backend.seeks.length, before);
      await f.finish(tester);
    },
  );

  testWidgets(
    'failed speed restore while locking unlocks and keeps the real failure visible',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final hold = await tester.startGesture(const Offset(450, 250));
      await tester.pump(const Duration(milliseconds: 700));
      f.backend.rejectRestore = true;
      final dynamic state = tester.state(find.byType(PlayerPage));
      state.toggleLock();
      await tester.pumpAndSettle();
      await hold.up();
      await tester.pumpAndSettle();
      expect(state.locked, isFalse);
      expect(
        f.backend.speed,
        3,
        reason: 'a rejected native rate must not be claimed as restored',
      );
      expect(
        find.textContaining('synthetic restore rejected').hitTestable(),
        findsOneWidget,
      );
      await f.finish(tester);
    },
  );

  testWidgets(
    'background stops sampling and restores hold without automatic resume',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final hold = await tester.startGesture(const Offset(450, 250));
      await tester.pump(const Duration(milliseconds: 700));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(f.session.holdingSpeed, isFalse);
      expect(f.backend.speed, 1);
      final samples = f.statusSamples, plays = f.backend.plays;
      await tester.pump(const Duration(seconds: 5));
      expect(f.statusSamples, samples);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await hold.up();
      expect(f.backend.plays, plays);
      expect(f.backend.snapshot.playing, isFalse);
      await f.finish(tester);
    },
  );

  testWidgets('status query failure never interrupts playback', (tester) async {
    final f = _Fixture()..statusFails = true;
    await f.mount(tester);
    expect(f.backend.snapshot.playing, isTrue);
    expect(f.session.error, isNull);
    expect(find.text('— KB/s').hitTestable(), findsOneWidget);
    await f.finish(tester);
  });

  testWidgets(
    'a real playback failure unlocks and leaves the failure visible',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      await f.lock(tester);
      f.backend.failures.add('合成播放失败');
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      expect(state.locked, isFalse);
      expect(find.textContaining('合成播放失败'), findsOneWidget);
      expect(find.byTooltip('退出播放').hitTestable(), findsOneWidget);
      await f.finish(tester);
    },
  );

  testWidgets('system back exits a locked player and saves stopped progress', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await f.backend.seek(const Duration(seconds: 35));
    await tester.pump();
    await f.lock(tester);
    await tester.binding.handlePopRoute();
    await settleOffline(tester);
    expect(find.byType(PlayerPage), findsNothing);
    expect(find.text('returned'), findsOneWidget);
    expect(f.session.closed, isTrue);
    expect(f.reports.any((path) => path.endsWith('/Stopped')), isTrue);
    final samples = f.statusSamples;
    await tester.pump(const Duration(seconds: 5));
    expect(f.statusSamples, samples);
    await f.finish(tester);
  });

  testWidgets('a replacement playback session clears touch lock', (
    tester,
  ) async {
    final f = _Fixture();
    await f.mount(tester);
    await f.lock(tester);
    final dynamic state = tester.state(find.byType(PlayerPage));
    state.retry();
    await settleOffline(tester);
    expect(f.sessions.length, 2);
    expect(state.locked, isFalse);
    expect(find.byTooltip('锁定屏幕').hitTestable(), findsOneWidget);
    expect(f.session.ready, isTrue);
    await f.finish(tester);
  });
}
