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
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
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

  for (final direction in [-1.0, 1.0]) {
    testWidgets(
      'tiny residual motion $direction after drag recognition never seeks',
      (tester) async {
        await mount(tester);
        try {
          final beforePreview = tester
              .widget<Slider>(find.byKey(const Key('playback-timeline')))
              .value;
          final pointer = await tester.startGesture(const Offset(500, 300));
          await pointer.moveBy(Offset(20 * direction, 0));
          await pointer.moveBy(Offset(4 * direction, 0));
          await tester.pump();
          final duringPreview = tester
              .widget<Slider>(find.byKey(const Key('playback-timeline')))
              .value;
          expect(
            (duringPreview - beforePreview) * direction,
            greaterThan(0),
            reason: 'Preview must follow immediately even for small motion',
          );
          expect(backend.seeks, isEmpty);
          await pointer.up();
          await tester.pumpAndSettle();
          expect(
            backend.seeks,
            isEmpty,
            reason:
                'Minor finger drift must not cause a native seek and buffer restart',
          );
        } finally {
          await finish(tester);
        }
      },
    );
    testWidgets(
      'deliberate horizontal motion $direction still seeks exactly once',
      (tester) async {
        await mount(tester);
        try {
          final before = session.position;
          final pointer = await tester.startGesture(const Offset(500, 300));
          await pointer.moveBy(Offset(20 * direction, 0));
          await pointer.moveBy(Offset(80 * direction, 0));
          await pointer.up();
          await tester.pumpAndSettle();
          expect(backend.seeks, hasLength(1));
          expect(
            (backend.seeks.single - before).inMilliseconds * direction,
            greaterThan(1000),
          );
        } finally {
          await finish(tester);
        }
      },
    );
  }
  testWidgets(
    'a short deliberate swipe follows immediately and commits without a delay',
    (tester) async {
      await mount(tester);
      try {
        final before = tester
            .widget<Slider>(find.byKey(const Key('playback-timeline')))
            .value;
        final pointer = await tester.startGesture(const Offset(500, 300));
        await pointer.moveBy(const Offset(20, 0));
        await pointer.moveBy(const Offset(8, 0));
        await tester.pump();
        expect(
          tester
              .widget<Slider>(find.byKey(const Key('playback-timeline')))
              .value,
          greaterThan(before),
        );
        expect(backend.seeks, isEmpty);
        await pointer.up();
        await tester.pump();
        expect(backend.seeks, hasLength(1));
        await tester.pumpAndSettle();
      } finally {
        await finish(tester);
      }
    },
  );
  for (final cancel in [false, true]) {
    testWidgets(
      'drag returning near its anchor or cancellation never commits: cancel=$cancel',
      (tester) async {
        await mount(tester);
        try {
          final pointer = await tester.startGesture(const Offset(500, 300));
          await pointer.moveBy(const Offset(20, 0));
          await pointer.moveBy(const Offset(80, 0));
          if (cancel) {
            await pointer.cancel();
          } else {
            await pointer.moveBy(const Offset(-78, 0));
            await pointer.up();
          }
          await tester.pumpAndSettle();
          expect(backend.seeks, isEmpty);
        } finally {
          await finish(tester);
        }
      },
    );
  }
}
