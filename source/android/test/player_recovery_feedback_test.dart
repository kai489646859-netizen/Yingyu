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
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;
import 'sync_ui_test.dart' show NoticeBackend;

class ClosingBackend extends FakeBackend {
  final closeGate = Completer<void>();
  @override
  Future<void> open(PlaybackRoute route, Duration start) async =>
      throw const AppFailure('合成断链');
  @override
  Future<void> dispose() async {
    await closeGate.future;
    await super.dispose();
  }
}

void main() {
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
  EmbyClient makeApi() => EmbyClient(
    client: MockClient(
      (req) async => req.url.path.endsWith('PlaybackInfo')
          ? response(jsonEncode(playbackData()), 200)
          : req.url.path.contains('Sessions/Playing')
          ? response('', 204)
          : response('{"Id":"movie","Type":"Movie"}', 200),
    ),
  )..session = syntheticSession();

  for (final previous in [1.25, 2.0]) {
    testWidgets(
      'held 3x displays only the held rate and restores $previous after release and cancel',
      (tester) async {
        final store = AppStore(await SharedPreferences.getInstance()),
            api = makeApi();
        final backend = FakeBackend()..gate.complete();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        await tester.pumpWidget(
          MaterialApp(home: PlayerPage(createSession: () => session)),
        );
        await tester.pumpAndSettle();
        await session.setSpeed(previous);
        for (final cancel in [false, true]) {
          final hold = await tester.startGesture(const Offset(400, 300));
          await tester.pump(const Duration(milliseconds: 650));
          expect(find.text('3倍速'), findsOneWidget);
          expect(backend.speed, 3);
          cancel ? await hold.cancel() : await hold.up();
          await tester.pump();
          await tester.pumpAndSettle();
          expect(session.speed, previous);
          expect(backend.speed, previous);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(backend.dispose);
        api.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'thirteen rapid retry presses create exactly one replacement player',
    (tester) async {
      final store = AppStore(await SharedPreferences.getInstance()),
          api = makeApi();
      final old = ClosingBackend(), backends = <FakeBackend>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            createSession: () {
              final backend = backends.isEmpty
                  ? old
                  : (FakeBackend()..gate.complete());
              backends.add(backend);
              return PlaybackSession(
                api: api,
                store: store,
                item: MediaItem({'Id': 'movie'}),
                backend: backend,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final retry = tester
          .widget<MessagePanel>(find.byType(MessagePanel))
          .retry!;
      final pending = [for (var i = 0; i < 13; i++) Future.sync(retry)];
      await tester.pump();
      expect(
        find.text('重试'),
        findsNothing,
        reason: 'retry becomes unavailable before closing awaits',
      );
      old.closeGate.complete();
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
      await Future.wait(pending);
      expect(backends.length, 2);
      expect(backends.last.plays, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        for (final b in backends) {
          await b.dispose();
        }
      });
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'source notice remains mounted with brightness volume and held speed until its original deadline',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = AppStore(await SharedPreferences.getInstance()),
          api = makeApi();
      final backend = NoticeBackend()..gate.complete();
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            createSession: () => PlaybackSession(
              api: api,
              store: store,
              item: MediaItem({'Id': 'movie'}),
              backend: backend,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final notice = tester.state(find.byType(SourceFormatNotice));
      for (final x in [220.0, 1060.0]) {
        final drag = await tester.startGesture(Offset(x, 400));
        await drag.moveBy(const Offset(0, -40));
        await drag.moveBy(const Offset(0, -70));
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(
            ValueKey(
              x < 640 ? 'brightness-level-feedback' : 'volume-level-feedback',
            ),
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('source-notice')), findsOneWidget);
        expect(tester.state(find.byType(SourceFormatNotice)), same(notice));
        await drag.up();
        await tester.pump();
      }
      final hold = await tester.startGesture(const Offset(640, 400));
      await tester.pump(const Duration(milliseconds: 650));
      expect(find.text('3倍速'), findsOneWidget);
      expect(tester.state(find.byType(SourceFormatNotice)), same(notice));
      expect(
        tester
            .getRect(find.byKey(const Key('playback-gesture-feedback')))
            .overlaps(tester.getRect(find.byType(SourceFormatNotice))),
        false,
      );
      await hold.up();
      await tester.pump(const Duration(seconds: 8));
      expect(find.byKey(const Key('source-notice')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(backend.dispose);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      expect(tester.takeException(), null);
    },
  );
}
