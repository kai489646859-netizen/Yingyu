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
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class _RatesBackend extends FakeBackend {
  final rates = <double>[];
  @override
  Future<void> rate(double value) async {
    rates.add(value);
    await super.rate(value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late _RatesBackend backend;
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
  Future<void> mount(WidgetTester tester) async {
    store = AppStore(await SharedPreferences.getInstance());
    api = EmbyClient(
      client: MockClient(
        (r) async => r.url.path.endsWith('PlaybackInfo')
            ? response(jsonEncode(playbackData()), 200)
            : r.url.path.contains('Sessions/Playing')
            ? response('', 204)
            : response('{"Id":"movie","Type":"Movie"}', 200),
      ),
    )..session = syntheticSession();
    backend = _RatesBackend()..gate.complete();
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

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Device.channel, null),
  );

  Future<TestGesture> hold(WidgetTester tester) async {
    final gesture = await tester.startGesture(const Offset(400, 280));
    await tester.pump(const Duration(milliseconds: 650));
    return gesture;
  }

  testWidgets(
    'quick repeated holds restore the original 1.5x immediately on every release',
    (tester) async {
      await mount(tester);
      await session.setSpeed(1.5);
      final first = await hold(tester);
      expect(backend.speed, 3);
      await first.up();
      await tester.pump();
      expect(backend.speed, 1.5);
      expect(find.text('3倍速'), findsNothing);
      final second = await hold(tester);
      expect(backend.rates, [1.5, 3, 1.5, 3]);
      await second.up();
      await tester.pump();
      expect(backend.speed, 1.5);
      expect(backend.rates, [1.5, 3, 1.5, 3, 1.5]);
      expect(find.text('3倍速'), findsNothing);
      expect(backend.plays, 1);
      await finish(tester);
    },
  );

  testWidgets(
    'release restores 1x immediately before a later explicit 2x menu choice',
    (tester) async {
      await mount(tester);
      final gesture = await hold(tester);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('播放速度'));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.text('2.0×'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(backend.rates, [3, 1, 2]);
      expect(find.text('3倍速'), findsNothing);
      expect(backend.plays, 1);
      await finish(tester);
    },
  );

  testWidgets(
    'volume feedback keeps its position after an immediate speed restore',
    (tester) async {
      await mount(tester);
      final gesture = await hold(tester);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 100));
      final volume = await tester.startGesture(const Offset(620, 250));
      await volume.moveBy(const Offset(0, -100));
      await volume.moveBy(const Offset(0, -60));
      await tester.pump();
      final feedback = tester.widget<PlaybackLevelFeedback>(
        find.byType(PlaybackLevelFeedback),
      );
      expect(feedback.brightness, isFalse);
      expect(feedback.level, inInclusiveRange(0, 1));
      expect(backend.speed, 1);
      await volume.up();
      await tester.pump(const Duration(seconds: 1));
      expect(backend.speed, 1);
      await finish(tester);
    },
  );

  for (final boundary in [
    'pause',
    'seek',
    'background',
    'buffer',
    'close',
    'error',
  ]) {
    testWidgets(
      'released speed remains restored on $boundary with no stale write',
      (tester) async {
        await mount(tester);
        final gesture = await hold(tester);
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 100));
        expect(backend.speed, 1);
        switch (boundary) {
          case 'pause':
            await session.toggle();
          case 'seek':
            await session.seek(const Duration(seconds: 60));
          case 'background':
            await session.pauseForBackground();
          case 'buffer':
            backend.snapshot = const PlaybackSnapshot(
              playing: true,
              buffering: true,
              duration: Duration(minutes: 90),
            );
            backend.updates.add(backend.snapshot);
            await tester.pump();
          case 'close':
            unawaited(session.close());
            await tester.pump();
          case 'error':
            backend.failures.add('synthetic terminal playback error');
            await tester.pump();
        }
        expect(backend.rates, [3, 1]);
        final completed = List<double>.of(backend.rates);
        await tester.pump(const Duration(seconds: 2));
        expect(backend.rates, completed);
        if (boundary == 'close') {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
          expect(
            backend.disposed,
            isTrue,
            reason: store.log.entries.map((e) => e.message).join('\n'),
          );
        }
        expect(backend.plays, 1);
        if (boundary == 'error') {
          expect(session.error, contains('synthetic terminal'));
        }
        if (boundary == 'pause' || boundary == 'background') {
          expect(backend.snapshot.playing, false);
        }
        if (boundary == 'seek') {
          expect(session.position, const Duration(seconds: 60));
        }
        await finish(tester);
      },
    );
  }

  testWidgets(
    'explicit menu choice during a hold becomes the base and cannot be undone by release',
    (tester) async {
      await mount(tester);
      final gesture = await hold(tester);
      final choice = session.setSpeed(2, source: SpeedChangeSource.menu);
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      await choice;
      expect(backend.rates, [3, 2]);
      final again = await hold(tester);
      await again.cancel();
      await tester.pump(const Duration(seconds: 1));
      expect(backend.rates, [3, 2, 3, 2]);
      await finish(tester);
    },
  );
}
