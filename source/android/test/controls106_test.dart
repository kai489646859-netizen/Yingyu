import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, playbackData, response;
import 'playback_test.dart' show FakeBackend;
import 'offline_settle.dart';

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

  testWidgets('battery is a small unnumbered theme-colored indicator', (
    tester,
  ) async {
    for (final accent in [AppAccent.blush, AppAccent.rose]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark, accentChoice: accent),
          home: const Center(child: PlayerBattery(percent: 42, charging: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('42'), findsNothing);
      final size = tester.getSize(find.byKey(const Key('player-battery')));
      expect(size.width, lessThanOrEqualTo(28));
      expect(size.height, lessThanOrEqualTo(14));
      expect(find.byKey(const Key('player-battery-charging')), findsOneWidget);
    }
  });

  for (final task in ['fit', 'paused']) {
    testWidgets('$task controls work directly without resuming playback', (
      tester,
    ) async {
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final api = EmbyClient(
        client: MockClient(
          (r) async => r.url.path.endsWith('PlaybackInfo')
              ? response(jsonEncode(playbackData()), 200)
              : r.url.path.contains('Sessions/Playing')
              ? response('', 204)
              : response('{"Id":"movie","Type":"Movie"}', 200),
        ),
      )..session = syntheticSession();
      final backend = FakeBackend()..gate.complete();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      addTearDown(() async {
        await tester.runAsync(() async {
          await session.close().timeout(const Duration(seconds: 5));
          await store.log.flush();
        });
        await tester.pumpWidget(const SizedBox());
        await settleOffline(tester);
        api.close();
        store.log.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(home: PlayerPage(createSession: () => session)),
      );
      await settleOffline(tester);
      expect(session.ready, true);
      if (task == 'fit') {
        expect(
          tester.widget<PlayerChrome>(find.byType(PlayerChrome)).filled,
          false,
        );
        await tester.tap(find.byTooltip('画面比例'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('fit')), findsNothing);
        expect(
          tester.widget<PlayerChrome>(find.byType(PlayerChrome)).filled,
          true,
        );
        await tester.tap(find.byTooltip('画面比例'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<PlayerChrome>(find.byType(PlayerChrome)).filled,
          false,
        );
      } else {
        await tester.tap(find.byTooltip('暂停'));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 3300));
        expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 2000));
        await tester.pumpAndSettle();
        expect(backend.snapshot.playing, false);
        expect(find.byTooltip('播放').hitTestable(), findsNothing);
        await tester.tapAt(const Offset(400, 300));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.byTooltip('播放').hitTestable(), findsOneWidget);
        expect(backend.snapshot.playing, false);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
