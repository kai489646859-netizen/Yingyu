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
import 'package:yingyu/playback/orientation.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

void main() {
  for (final spec in [
    ('portrait tablet', const Size(800, 1280), false),
    ('landscape tablet', const Size(1280, 800), false),
    ('phone', const Size(360, 800), true),
  ]) {
    testWidgets('${spec.$1} restores direction before revealing the browser', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final item = MediaItem({'Id': 'test', 'Name': 'test', 'Type': 'Movie'});
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            return response('', 204);
          }
          return response(jsonEncode(item.data), 200);
        }),
      )..session = syntheticSession();
      final backend = FakeBackend()..gate.complete();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: item,
        backend: backend,
      );
      final calls = <String>[];
      final release = Completer<void>();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        Device.channel,
        (call) async => call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null,
      );
      messenger.setMockMethodCallHandler(PlaybackOrientation.channel, (
        call,
      ) async {
        calls.add(
          call.method == 'player'
              ? 'player:${call.arguments['active']}'
              : call.method,
        );
        if (call.method == 'player' && call.arguments['active'] == false) {
          await release.future;
        }
        return call.method == 'player' ? {'phone': spec.$3} : null;
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('browser')),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerPage(createSession: () => session),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.ready, isTrue);
      final dynamic state = tester.state(find.byType(PlayerPage));
      var done = false;
      final leave = (state.leave() as Future<void>).whenComplete(
        () => done = true,
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(calls, contains('player:false'));
      expect(
        done,
        isFalse,
        reason: 'browser cannot be popped before the release acknowledgement',
      );
      tester.view.physicalSize = spec.$2;
      release.complete();
      for (var i = 0; i < 30 && !done; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        done,
        isTrue,
        reason: 'exit must finish within bounded frames and real IO turns',
      );
      await leave;
      await tester.pumpAndSettle();
      expect(find.byType(PlayerPage), findsNothing);
      expect(tester.view.physicalSize, spec.$2);
      expect(calls.last, 'finishExit');
      expect(calls.where((s) => s == 'player:false').length, 1);
      expect(tester.takeException(), isNull);
      messenger.setMockMethodCallHandler(Device.channel, null);
      messenger.setMockMethodCallHandler(PlaybackOrientation.channel, null);
      await tester.runAsync(backend.dispose);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    });
  }
}
