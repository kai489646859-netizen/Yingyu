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
import 'package:yingyu/playback/orientation.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'player page keeps landscape ownership through menus, retry and episode change',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      MediaItem episode(String id) => MediaItem({
        'Id': id,
        'Name': id,
        'Type': 'Episode',
        'SeriesId': 'series',
        'SeasonId': 'season',
        'IndexNumber': id == 'one' ? 1 : 2,
      });
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            return response('', 204);
          }
          if (request.url.path.endsWith('/Episodes')) {
            return response(
              jsonEncode({
                'Items': [episode('one').data, episode('two').data],
              }),
              200,
            );
          }
          return response(
            jsonEncode(episode(request.url.path.split('/').last).data),
            200,
          );
        }),
      )..session = syntheticSession();
      final calls = <MethodCall>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PlaybackOrientation.channel, (
        call,
      ) async {
        calls.add(call);
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
      final sessions = <PlaybackSession>[];
      PlaybackSession make(MediaItem item) {
        final session = PlaybackSession(
          api: api,
          store: store,
          item: item,
          backend: FakeBackend()..gate.complete(),
        );
        sessions.add(session);
        return session;
      }

      addTearDown(() {
        messenger.setMockMethodCallHandler(Device.channel, null);
        messenger.setMockMethodCallHandler(PlaybackOrientation.channel, null);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            createSession: () => make(episode('one')),
            createSessionForItem: make,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sessions.single.ready, true);
      expect(calls.single.arguments['active'], true);
      final owner = calls.single.arguments['owner'];
      await tester.tap(find.byTooltip('播放器菜单'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      Navigator.of(tester.element(find.byType(PlayerPage))).pop();
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      Future<void> settleOperation(Future<void> operation) async {
        var done = false;
        final observed = operation.whenComplete(() => done = true);
        for (var i = 0; i < 40 && !done; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          done,
          true,
          reason: 'synthetic operation must finish within bounded frames',
        );
        await observed;
      }

      await settleOperation(state.retry() as Future<void>);
      await tester.pumpAndSettle();
      expect(sessions.length, 2);
      expect(sessions.last.ready, true);
      expect(calls.length, 1);
      await settleOperation(
        state.switchEpisode(episode('two')) as Future<void>,
      );
      await tester.pumpAndSettle();
      expect(sessions.last.item.id, 'two');
      expect(sessions.last.ready, true);
      expect(calls.length, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      final playerCalls = calls.where((call) => call.method == 'player').toList();
      expect(playerCalls.length, 2);
      expect(playerCalls.last.arguments, {'owner': owner, 'active': false});
      expect(calls.last.method, 'finishExit');
      expect(tester.takeException(), isNull);
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(sessions.every((s) => (s.backend as FakeBackend).disposed), true);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    },
  );
}
