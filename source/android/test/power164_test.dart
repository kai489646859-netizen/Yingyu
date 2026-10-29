import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/library_events.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/device_awake.dart';
import 'package:yingyu/core/offline_translation.dart';
import 'package:yingyu/ui/offline_translation.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;
import 'offline_settle.dart' show settleOffline;

class CountingBackend extends FakeBackend {
  int views = 0;
  @override
  Widget view(BoxFit fit) {
    views++;
    return super.view(fit);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('unresponsive awake reply cannot block exit indefinitely', (
    tester,
  ) async {
    final lateReply = Completer<void>();
    var calls = 0;
    final awake = PlayerAwake(
      write: (_) {
        calls++;
        return lateReply.future;
      },
    );
    final failed = expectLater(
      awake.update(true),
      throwsA(isA<TimeoutException>()),
    );
    await tester.pump();
    final closed = awake.close();
    await tester.pump(const Duration(milliseconds: 701));
    await failed;
    await closed;
    lateReply.complete();
    await tester.pump();
    await awake.update(true);
    expect(calls, 1);
  });
  test(
    'awake retries a rejected write and drains before releasing ownership',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final awake = PlayerAwake(
        write: (_) async {
          calls++;
          if (calls == 1) throw StateError('injected failure');
          await gate.future;
        },
      );
      await expectLater(awake.update(true), throwsStateError);
      final pending = awake.update(true);
      for (var i = 0; i < 30; i++) {
        awake.update(true);
      }
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      var closed = false;
      final closing = awake.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, false);
      gate.complete();
      await pending;
      await closing;
      await awake.update(true);
      expect(calls, 2);
    },
  );
  testWidgets(
    'hidden translation settings cancel status polling and resume on return',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final service = OfflineTranslation(await SharedPreferences.getInstance());
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AndroidTranslationPlatform.channel,
        (call) async {
          if (call.method == 'status') reads++;
          return {'ready': false, 'phase': 'downloading'};
        },
      );
      final visible = ValueNotifier(true);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: visible,
            builder: (_, active, child) =>
                TickerMode(enabled: active, child: child!),
            child: Scaffold(
              body: SingleChildScrollView(
                child: OfflineTranslationGroup(service: service),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final dynamic state = tester.state(find.byType(OfflineTranslationGroup));
      expect(state.poll?.isActive, true);
      visible.value = false;
      await tester.pump();
      expect(state.poll, null);
      final hiddenReads = reads;
      await tester.pump(const Duration(minutes: 16));
      await tester.pump();
      expect(reads, hiddenReads);
      visible.value = true;
      await tester.pump();
      await tester.pump();
      expect(reads, greaterThan(hiddenReads));
      expect(state.poll?.isActive, true);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
      visible.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AndroidTranslationPlatform.channel,
        null,
      );
    },
  );
  testWidgets(
    'position and status updates keep video tree and awake state stable',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            return response('', 204);
          }
          return response(
            '{"Id":"movie","Type":"Movie","RunTimeTicks":54000000000}',
            200,
          );
        }),
      )..session = syntheticSession();
      final backend = CountingBackend()..gate.complete();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      final awake = <bool>[];
      var statusReads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        Device.channel,
        (call) async {
          if (call.method == 'awake') awake.add(call.arguments as bool);
          if (call.method == 'focus') return true;
          if (call.method == 'levels') return {'brightness': .5, 'volume': .5};
          return null;
        },
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlayerStatusController.channel,
        (call) async {
          if (call.method != 'reset') statusReads++;
          return {
            'wallTimeMs': 1000000,
            'rxBytesPerSecond': 2048,
            'batteryPercent': 70,
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: PlayerPage(createSession: () => session)),
      );
      await settleOffline(tester);
      expect(session.ready, true);
      final beforeViews = backend.views, beforeAwake = awake.length;
      for (var i = 1; i <= 20; i++) {
        backend.snapshot = PlaybackSnapshot(
          playing: true,
          position: Duration(seconds: i),
          duration: const Duration(minutes: 90),
        );
        backend.updates.add(backend.snapshot);
        await tester.pump(const Duration(milliseconds: 20));
      }
      final positionViews = backend.views - beforeViews;
      final positionAwake = awake.length - beforeAwake;
      final statusBefore = backend.views;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      final statusViews = backend.views - statusBefore;
      final shown = tester.widget<PlayerChrome>(find.byType(PlayerChrome));
      expect(shown.position, const Duration(seconds: 20));
      expect(find.byTooltip('截图'), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump();
      await session.toggle();
      await tester.pump();
      expect(
        tester.widget<PlayerChrome>(find.byType(PlayerChrome)).playing,
        false,
      );
      expect(awake.last, false);
      final readsWhenPaused = statusReads;
      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      expect(statusReads, readsWhenPaused);
      await session.toggle();
      await tester.pump();
      expect(awake.last, true);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(statusReads, greaterThan(readsWhenPaused));
      await tester.pumpWidget(const SizedBox());
      await settleOffline(tester);
      await tester.runAsync(backend.dispose);
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
      // Counts measure production UI/IPC work, not battery power or Android decoding.
      debugPrint(
        'POWER164 positionViews=$positionViews positionAwake=$positionAwake statusViews=$statusViews',
      );
      expect(positionViews, 0);
      expect(positionAwake, 0);
      expect(statusViews, 0);
    },
  );

  testWidgets(
    'optional socket disconnects for playback and resumes only after all owners release',
    (tester) async {
      final api = EmbyClient()..session = syntheticSession();
      var connects = 0, closes = 0;
      final streams = <StreamController<dynamic>>[];
      final events = LibraryEvents(
        api,
        onChanges: (_, _) async {},
        connect: (_) async {
          connects++;
          final stream = StreamController<dynamic>();
          streams.add(stream);
          return LibraryEventChannel(stream.stream, (_) {}, () async {
            closes++;
            await stream.close();
          });
        },
      );
      events.setActive(true);
      await tester.pump();
      expect(events.connected, true);
      final playback = Object(), background = Object();
      api.backgroundWork.pause(playback, true);
      await tester.pump();
      final pausedConnected = events.connected, pausedCloses = closes;
      api.backgroundWork.pause(background, true);
      api.backgroundWork.pause(playback, false);
      await tester.pump(const Duration(minutes: 16));
      final pausedConnects = connects;
      api.backgroundWork.pause(background, false);
      await tester.pump();
      final resumedConnects = connects;
      events.dispose();
      await tester.pump();
      api.close();
      expect(pausedConnected, false);
      expect(pausedCloses, 1);
      expect(pausedConnects, 1);
      expect(resumedConnects, 2);
    },
  );
}
