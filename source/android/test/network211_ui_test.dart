import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/network_route.dart';
import 'package:yingyu/playback/network_recovery.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class _NetworkBackend extends FakeBackend implements NetworkRecoveryBackend {
  int recoveries = 0;
  @override
  Future<void> recoverNetwork(bool Function() current) async {
    if (current()) recoveries++;
  }
}

void main() {
  for (final paused in [false, true]) {
    testWidgets('mobile transition notifies and preserves paused=$paused', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final messenger = tester.binding.defaultBinaryMessenger;
      const events = MethodChannel('yingyu/playback-network');
      var cancelled = false;
      messenger.setMockMethodCallHandler(events, (call) async {
        if (call.method == 'cancel') cancelled = true;
        return null;
      });
      messenger.setMockMethodCallHandler(
        Device.channel,
        (call) async => call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null,
      );
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
      final backend = _NetworkBackend()..gate.complete();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      Future<void> event(int id, String kind) async {
        await messenger.handlePlatformMessage(
          PlaybackNetworkRoutes.channel.name,
          const StandardMethodCodec().encodeSuccessEnvelope({
            'route': id,
            'kind': kind,
            'available': true,
          }),
          (_) {},
        );
        await tester.pump();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              createSession: () => session,
              networkEvents: PlaybackNetworkRoutes.channel
                  .receiveBroadcastStream(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await event(1, 'wifi');
        if (paused) await backend.pause();
        await tester.pump();
        final plays = backend.plays;
        await event(2, 'mobile');
        expect(find.text('已切换到手机流量'), findsOneWidget);
        expect(backend.plays, plays);
        expect(backend.snapshot.playing, !paused);
        backend.snapshot = PlaybackSnapshot(
          playing: !paused,
          buffering: true,
          position: const Duration(seconds: 50),
          duration: const Duration(minutes: 90),
        );
        backend.updates.add(backend.snapshot);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(backend.recoveries, paused ? 0 : 1);
        expect(backend.speed, 1);
        expect(backend.plays, plays);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await store.log.flush();
        store.log.dispose();
        expect(cancelled, isTrue);
        messenger.setMockMethodCallHandler(events, null);
        messenger.setMockMethodCallHandler(Device.channel, null);
      }
    });
  }
}
