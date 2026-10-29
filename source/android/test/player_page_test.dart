import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class FakeDiscBackend extends FakeBackend implements DiscNavigationBackend {
  @override
  int? discPlaylist;
  @override
  DiscKind? forcedDiscKind;
  @override
  int? get selectedDiscPlaylist => discPlaylist ?? 1;
  @override
  List<DiscTitle> get discTitles => [
    for (var i = 1; i <= 2; i++)
      DiscTitle({
        'playlist': i,
        'duration': 90000 * 60 * i,
        'clips': [
          {'id': '00001', 'in': 0, 'out': 90000 * 60 * i},
        ],
        'chapters': [0],
      }),
  ];
}

void main() {
  testWidgets(
    'disc title and opaque STRM mode selection reopen through a fake backend',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        Device.channel,
        (call) async => call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(Device.channel, null),
      );
      SharedPreferences.setMockInitialValues({
        'yingyu.ui.controlsSeconds.v1': 8,
      });
      final store = AppStore(await SharedPreferences.getInstance());
      final api = EmbyClient(
        client: MockClient(
          (request) async => request.url.path.endsWith('PlaybackInfo')
              ? response(jsonEncode(playbackData()), 200)
              : request.url.path.contains('Sessions/Playing')
              ? response('', 204)
              : response('{"Id":"movie","Type":"Movie"}', 200),
        ),
      )..session = syntheticSession();
      final backends = <FakeDiscBackend>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            createSession: () {
              final backend = FakeDiscBackend()..gate.complete();
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
      await tester.tap(find.byTooltip('播放器菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原盘播放'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await tester.tap(find.text('播放列表 00002 · 2 分钟'));
      await tester.pump();
      // Subscription cancellation crosses Flutter's fake/real async zones.
      for (var i = 0; i < 20 && backends.length < 2; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(backends.length, 2);
      expect(backends.first.disposed, true);
      expect(backends.last.discPlaylist, 2);
      expect(backends.last.initial, Duration.zero);
      await tester.tap(find.byTooltip('播放器菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原盘播放'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      await tester.tap(find.text('按蓝光 ISO 读取'));
      await tester.pump();
      for (var i = 0; i < 20 && backends.length < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(backends.length, 3);
      expect(backends.last.forcedDiscKind, DiscKind.iso);
      expect(store.discKind(api.session!, 'movie', 'source-1'), DiscKind.iso);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      for (var i = 0; i < 20 && !backends.last.disposed; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(backends.every((b) => b.disposed), true);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    },
  );
  testWidgets(
    'player gestures and lifecycle use fake backend, never native MPV',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(Device.channel, (call) async {
        calls.add(call);
        if (call.method == 'focus') return true;
        if (call.method == 'levels') return {'brightness': .5, 'volume': .5};
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(Device.channel, null),
      );
      SharedPreferences.setMockInitialValues({
        'yingyu.ui.controlsSeconds.v1': 8,
      });
      final store = AppStore(await SharedPreferences.getInstance());
      final backend = FakeBackend()..gate.complete();
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            return response('', 204);
          }
          return response('{"Id":"movie","Type":"Movie"}', 200);
        }),
      )..session = syntheticSession();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie', 'Name': '合成播放测试'}),
        backend: backend,
      );
      await tester.pumpWidget(
        MaterialApp(home: PlayerPage(createSession: () => session)),
      );
      await tester.pumpAndSettle();
      expect(session.ready, true);
      expect(backend.snapshot.playing, true);
      // Notification shade and side panels make Flutter inactive while the
      // player remains visible. They must not turn a playing session into pause.
      for (var attempt = 0; attempt < 2; attempt++) {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(backend.snapshot.playing, true);
        expect(session.background, false);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(backend.snapshot.playing, true);
      }
      // Reset the timer through the normal single-tap interaction, then verify
      // the five-second deadline without loading a native decoder.
      await tester.tapAt(const Offset(800, 250));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(const Offset(800, 250));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 4500));
      expect(
        tester.widget<PlayerChrome>(find.byType(PlayerChrome)).visible,
        true,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        tester.widget<PlayerChrome>(find.byType(PlayerChrome)).visible,
        false,
      );
      await tester.tapAt(const Offset(800, 250));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(backend.snapshot.playing, false);
      await tester.pump(const Duration(seconds: 6));
      expect(
        tester.widget<PlayerChrome>(find.byType(PlayerChrome)).visible,
        false,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(backend.snapshot.playing, false);

      // Use the unobstructed upper-middle video area, outside all controls.
      await tester.tapAt(const Offset(800, 250));
      await tester.pump(const Duration(milliseconds: 70));
      await tester.tapAt(const Offset(800, 250));
      await tester.pumpAndSettle();
      expect(backend.snapshot.playing, true);
      await session.setSpeed(1.5);
      for (final x in [200.0, 640.0, 1000.0]) {
        final hold = await tester.startGesture(Offset(x, 250));
        await tester.pump(const Duration(milliseconds: 650));
        expect(backend.speed, 3);
        if (x == 640) {
          await hold.cancel();
        } else {
          await hold.up();
        }
        await tester.pump();
        await tester.pumpAndSettle();
        expect(backend.speed, 1.5);
      }

      await tester.dragFrom(const Offset(400, 250), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(session.position, greaterThan(Duration.zero));
      await tester.dragFrom(const Offset(200, 300), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'brightness'), isNotEmpty);
      await tester.dragFrom(const Offset(1000, 300), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'volume'), isNotEmpty);
      await messenger.handlePlatformMessage(
        Device.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('interruption', '耳机已断开'),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
      expect(backend.snapshot.playing, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      // Cancellation can cross Flutter's real and fake async zones. Drain both.
      for (var count = 0; count < 20 && !backend.disposed; count++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(backend.disposed, true);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    },
  );
}
