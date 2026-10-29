import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class GestureBackend extends FakeBackend {
  final seeks = <Duration>[];
  @override
  Future<void> seek(Duration value) async {
    seeks.add(value);
    await super.seek(value);
  }
}

void main() {
  late AppStore store;
  late EmbyClient api;
  late GestureBackend backend;
  late PlaybackSession session;
  final levelWrites = <String>[];
  setUp(() {
    levelWrites.clear();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Device.channel, (call) async {
          if (call.method == 'brightness' || call.method == 'volume') {
            levelWrites.add(call.method);
          }
          return call.method == 'focus'
              ? true
              : call.method == 'levels'
              ? {'brightness': .5, 'volume': .5}
              : null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(Device.channel, null),
  );
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(3168, 1440);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    backend = GestureBackend()
      ..gate.complete()
      ..snapshot = const PlaybackSnapshot(
        position: Duration(minutes: 10),
        duration: Duration(minutes: 90),
      );
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

  testWidgets(
    'clear short horizontal phone swipe still commits once immediately',
    (tester) async {
      await mount(tester);
      try {
        levelWrites.clear();
        final gesture = await tester.startGesture(const Offset(500, 200));
        await gesture.moveBy(const Offset(20, 0));
        await gesture.moveBy(const Offset(8, 1));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(backend.seeks, hasLength(1));
        expect(levelWrites, isEmpty);
      } finally {
        await finish(tester);
      }
    },
  );
  testWidgets(
    'vertical level intent cannot become seeking after sideways drift',
    (tester) async {
      await mount(tester);
      try {
        levelWrites.clear();
        final gesture = await tester.startGesture(const Offset(800, 200));
        await gesture.moveBy(const Offset(0, -20));
        await gesture.moveBy(const Offset(8, -20));
        await gesture.moveBy(const Offset(60, 0));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(backend.seeks, isEmpty);
        expect(levelWrites, contains('volume'));
      } finally {
        await finish(tester);
      }
    },
  );
  for (final left in [true, false]) {
    for (final sign in [-1.0, 1.0]) {
      testWidgets(
        'phone level micro-drag after initial horizontal drift must not seek, left=$left dy=$sign',
        (tester) async {
          await mount(tester);
          try {
            levelWrites.clear();
            final before = session.position;
            final gesture = await tester.startGesture(
              Offset(left ? 240 : 800, 200),
            );
            await gesture.moveBy(Offset(20, 12 * sign));
            await gesture.moveBy(Offset(12, 18 * sign));
            await tester.pump();
            await gesture.up();
            await tester.pumpAndSettle();
            expect(
              backend.seeks,
              isEmpty,
              reason:
                  'Fine brightness/volume motion must not commit a timeline seek.',
            );
            expect(levelWrites, contains(left ? 'brightness' : 'volume'));
            expect(session.position, before);
          } finally {
            await finish(tester);
          }
        },
      );
    }
  }
}
