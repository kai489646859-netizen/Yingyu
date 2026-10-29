import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          Device.channel,
          (call) async => call.method == 'focus'
              ? true
              : call.method == 'levels'
              ? {'brightness': .5, 'volume': .5}
              : null,
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Device.channel, null),
  );
  EmbyClient api() => EmbyClient(
    client: MockClient(
      (r) async => r.url.path.endsWith('PlaybackInfo')
          ? response(jsonEncode(playbackData()), 200)
          : r.url.path.contains('Sessions/Playing')
          ? response('', 204)
          : response('{"Id":"movie","Type":"Movie"}', 200),
    ),
  )..session = syntheticSession();

  test(
    'long-press defaults to 3, persists 2 and rejects unsupported values',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      expect(store.holdSpeed, 3);
      await store.setHoldSpeed(2);
      expect(AppStore(prefs).holdSpeed, 2);
      await store.setHoldSpeed(4);
      expect(store.holdSpeed, 2);
      await store.setHoldSpeed(3);
      expect(store.holdSpeed, 3);
      store.log.dispose();
      store.dispose();
    },
  );

  for (final speed in [2.0, 3.0]) {
    testWidgets(
      'loading blocks $speed from buttons, menu, hold and session calls',
      (tester) async {
        final store = AppStore(await SharedPreferences.getInstance()),
            client = api();
        final backend = FakeBackend();
        final session = PlaybackSession(
          api: client,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        await tester.pumpWidget(
          MaterialApp(home: PlayerPage(createSession: () => session)),
        );
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(session.ready, isFalse);
        expect(find.byKey(const Key('loading-playback-rate')), findsNothing);
        expect(find.byTooltip('播放速度'), findsNothing);
        await session.setSpeed(speed, source: SpeedChangeSource.menu);
        final hold = await tester.startGesture(const Offset(400, 300));
        await tester.pump(const Duration(milliseconds: 650));
        expect(find.text('3倍速'), findsNothing);
        await hold.up();
        expect(backend.speed, 1);
        expect(session.speed, 1);
        expect(backend.plays, 0);
        if (speed == 3) await session.pauseForBackground();
        backend.gate.complete();
        await tester.pumpAndSettle();
        expect(session.ready, isTrue);
        expect(session.speed, 1);
        expect(find.byKey(const Key('loading-playback-rate')), findsNothing);
        expect(backend.plays, speed == 3 ? 0 : 1);
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(backend.dispose);
        client.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('configured held 2x restores 1.5x on release and cancel', (
    tester,
  ) async {
    final store = AppStore(await SharedPreferences.getInstance()),
        client = api();
    await store.setHoldSpeed(2);
    final backend = FakeBackend()..gate.complete();
    final session = PlaybackSession(
      api: client,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    await tester.pumpWidget(
      MaterialApp(home: PlayerPage(createSession: () => session)),
    );
    await tester.pumpAndSettle();
    await session.setSpeed(1.5);
    for (final cancel in [false, true]) {
      final hold = await tester.startGesture(const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 650));
      expect(find.text('2倍速'), findsOneWidget);
      expect(backend.speed, 2);
      cancel ? await hold.cancel() : await hold.up();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(backend.speed, 1.5);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(backend.dispose);
    client.close();
    await store.log.flush();
    store.log.dispose();
    store.dispose();
  });

  testWidgets('buffering closes rate choices and cannot trap an active hold', (
    tester,
  ) async {
    final store = AppStore(await SharedPreferences.getInstance()),
        client = api();
    final backend = FakeBackend()..gate.complete();
    final session = PlaybackSession(
      api: client,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    await tester.pumpWidget(
      MaterialApp(home: PlayerPage(createSession: () => session)),
    );
    await tester.pumpAndSettle();
    await session.setSpeed(1.5);
    final hold = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 650));
    expect(backend.speed, 3);
    backend.snapshot = const PlaybackSnapshot(
      playing: true,
      buffering: true,
      duration: Duration(minutes: 90),
    );
    backend.updates.add(backend.snapshot);
    await tester.pump();
    await hold.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      backend.speed,
      1.5,
      reason: 'release remains allowed during buffering',
    );
    expect(find.byTooltip('播放速度'), findsNothing);
    final blockedHold = await tester.startGesture(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 650));
    expect(find.text('3倍速'), findsNothing);
    await blockedHold.up();
    await session.setSpeed(2, source: SpeedChangeSource.menu);
    expect(backend.speed, 1.5);
    backend.snapshot = const PlaybackSnapshot(
      playing: true,
      duration: Duration(minutes: 90),
    );
    backend.updates.add(backend.snapshot);
    await tester.pump();
    await tester.tap(find.byTooltip('播放速度'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('2.0×'), findsOneWidget);
    // A menu opened just before buffering must not offer stale actions.
    backend.snapshot = const PlaybackSnapshot(
      playing: true,
      buffering: true,
      duration: Duration(minutes: 90),
    );
    backend.updates.add(backend.snapshot);
    await tester.pump();
    expect(find.byType(PlayerMenu), findsOneWidget);
    expect(find.text('2.0×'), findsNothing);
    expect(find.text('加载完成后可调整倍速'), findsOneWidget);
    backend.snapshot = const PlaybackSnapshot(
      playing: true,
      duration: Duration(minutes: 90),
    );
    backend.updates.add(backend.snapshot);
    await tester.pump();
    await tester.tap(find.text('2.0×'));
    await tester.pumpAndSettle();
    expect(backend.speed, 2);
    expect(backend.plays, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(backend.dispose);
    client.close();
    store.log.dispose();
    store.dispose();
  });
}
