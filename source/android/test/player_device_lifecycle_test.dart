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
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'track_menu_test.dart' show MenuBackend;
import 'offline_settle.dart' show settleOffline;

void main() {
  testWidgets(
    'leave followed by dispose releases device once without brightness gestures',
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
          return response('{"Id":"movie","Type":"Movie"}', 200);
        }),
      )..session = syntheticSession();
      final backend = MenuBackend()..gate.complete();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      final navigator = GlobalKey<NavigatorState>();
      var releases = 0, brightnessWrites = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        Device.channel,
        (call) async {
          if (call.method == 'release') releases++;
          if (call.method == 'brightness') brightnessWrites++;
          if (call.method == 'focus') return true;
          if (call.method == 'levels') return {'brightness': .5, 'volume': .5};
          return null;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('returned')),
        ),
      );
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => PlayerPage(createSession: () => session),
        ),
      );
      await settleOffline(tester);
      expect(session.ready, true);
      await tester.tap(find.byTooltip('退出播放'));
      // Closing flushes the real local progress journal. Alternate real event
      // turns with frames, as in the existing account/playback UI fixtures.
      await settleOffline(tester);
      expect(releases, 1);
      expect(find.byType(PlayerPage), findsNothing);
      expect(find.text('returned'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(
        releases,
        1,
        reason: 'disposed old route must not reset a newly opened player',
      );
      expect(brightnessWrites, 0);
      await tester.runAsync(backend.dispose);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        Device.channel,
        null,
      );
    },
  );
}
