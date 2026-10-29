import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class _HoldBackend extends FakeBackend {
  final rates = <double>[];
  Completer<void>? nextRate;
  @override
  Future<void> rate(double value) async {
    rates.add(value);
    final gate = nextRate;
    nextRate = null;
    if (gate != null) await gate.future;
    await super.rate(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late _HoldBackend backend;
  late PlaybackSession session;
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

  Future<void> mount(WidgetTester tester, int holdSpeed) async {
    store = AppStore(await SharedPreferences.getInstance());
    await store.setHoldSpeed(holdSpeed);
    api = EmbyClient(
      client: MockClient(
        (r) async => r.url.path.endsWith('PlaybackInfo')
            ? response(jsonEncode(playbackData()), 200)
            : r.url.path.contains('Sessions/Playing')
            ? response('', 204)
            : response('{"Id":"movie","Type":"Movie"}', 200),
      ),
    )..session = syntheticSession();
    backend = _HoldBackend()..gate.complete();
    session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    await tester.pumpWidget(
      MaterialApp(home: PlayerPage(createSession: () => session)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(backend.dispose);
    api.close();
    await store.log.flush();
    store.log.dispose();
    store.dispose();
  }

  Future<TestGesture> hold(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(400, 280));
    await tester.pump(const Duration(milliseconds: 650));
    return gesture;
  }

  for (final scenario in [
    (selected: 3.0, held: 3, expected: 3.0),
    (selected: 2.0, held: 2, expected: 2.0),
    (selected: 3.0, held: 2, expected: 2.0),
    (selected: 2.0, held: 3, expected: 3.0),
    (selected: 1.5, held: 2, expected: 2.0),
    (selected: 1.0, held: 2, expected: 2.0),
  ]) {
    testWidgets(
      'selected ${scenario.selected}x and hold ${scenario.held}x show ${scenario.expected}x without redundant commands',
      (tester) async {
        await mount(tester, scenario.held);
        await session.setSpeed(
          scenario.selected,
          source: SpeedChangeSource.menu,
        );
        final before = List<double>.of(backend.rates);
        final gesture = await hold(tester);
        expect(backend.speed, scenario.expected);
        expect(session.holdingSpeed, isTrue);
        expect(find.text('${scenario.expected.toInt()}倍速'), findsOneWidget);
        expect(
          backend.rates,
          scenario.expected == scenario.selected
              ? before
              : [...before, scenario.expected],
        );
        await gesture.up();
        await tester.pump();
        expect(backend.speed, scenario.selected);
        expect(session.holdingSpeed, isFalse);
        expect(find.text('${scenario.expected.toInt()}倍速'), findsNothing);
        expect(
          backend.rates,
          scenario.expected == scenario.selected
              ? before
              : [...before, scenario.expected, scenario.selected],
        );
        expect(store.holdSpeed, scenario.held);
        expect(backend.plays, 1);
        await finish(tester);
      },
    );
  }

  testWidgets(
    'a new 2x hold follows an in-flight selected 3x and restores it',
    (tester) async {
      await mount(tester, 2);
      final gate = Completer<void>();
      backend.nextRate = gate;
      final choice = session.setSpeed(3, source: SpeedChangeSource.menu);
      final gesture = await hold(tester);
      expect(backend.rates, [3]);
      gate.complete();
      await choice;
      await tester.pump();
      expect(backend.rates, [3, 2]);
      expect(backend.speed, 2);
      expect(find.text('2倍速'), findsOneWidget);
      await gesture.cancel();
      await tester.pump(const Duration(seconds: 2));
      expect(backend.rates, [3, 2, 3]);
      expect(backend.speed, 3);
      expect(find.text('2倍速'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets('a 2x hold temporarily overrides the latest selected 3x', (
    tester,
  ) async {
    await mount(tester, 2);
    final gesture = await hold(tester);
    expect(backend.rates, [2]);
    await session.setSpeed(3, source: SpeedChangeSource.menu);
    await gesture.up();
    await tester.pump(const Duration(seconds: 2));
    expect(backend.rates, [2, 3]);
    final again = await hold(tester);
    expect(backend.speed, 2);
    expect(find.text('2倍速'), findsOneWidget);
    await again.up();
    await tester.pump(const Duration(seconds: 2));
    expect(backend.rates, [2, 3, 2, 3]);
    expect(backend.speed, 3);
    expect(store.holdSpeed, 2);
    await finish(tester);
  });

  testWidgets(
    'release hides the held tip before a slow native acknowledgement',
    (tester) async {
      await mount(tester, 3);
      final gesture = await hold(tester);
      expect(find.text('3倍速'), findsOneWidget);
      final gate = Completer<void>();
      backend.nextRate = gate;
      await gesture.up();
      await tester.pump();
      expect(backend.rates, [3, 1]);
      expect(find.text('3倍速'), findsNothing);
      expect(session.holdingSpeed, isFalse);
      gate.complete();
      await tester.pump();
      expect(backend.speed, 1);
      await tester.pump(const Duration(seconds: 5));
      expect(backend.rates, [3, 1]);
      await finish(tester);
    },
  );
}
