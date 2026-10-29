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
import 'package:yingyu/playback/opening_metadata.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;
import 'player_episode_menu_test.dart' show episode, page;
import 'opening_metadata098_test.dart' show DetailApi, item;

class PreparedApi extends DetailApi {
  PreparedApi() : super((id) async => item(id));
  int preparations = 0;
  @override
  Future<MediaItem> prepareEpisodeMetadata(String id) async {
    preparations++;
    return item(id);
  }
}

void main() {
  test(
    'prepared response survives the observed 5.53 second age without a second detail',
    () async {
      final api = PreparedApi();
      addTearDown(api.close);
      final metadata = OpeningMetadata.prepare(api, 'one');
      await Future<void>.delayed(const Duration(milliseconds: 5600));
      metadata.acceptIntent();
      expect(metadata.elapsedMilliseconds, lessThan(100));
      expect((await metadata.take(api, 'one')).resume, item('one').resume);
      expect(api.preparations, 1);
      expect(api.calls, 0);
      expect(metadata.refreshed, false);
      metadata.cancel();
    },
  );
  test(
    'prepared result held through a long pause refreshes once after thirty seconds',
    () async {
      final api = PreparedApi();
      addTearDown(api.close);
      final metadata = OpeningMetadata.prepare(api, 'one');
      await Future<void>.delayed(const Duration(milliseconds: 30100));
      expect((await metadata.take(api, 'one')).id, 'one');
      expect(api.preparations, 1);
      expect(api.calls, 1);
      expect(metadata.refreshed, true);
      metadata.cancel();
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );
  for (final transition in [
    'pause',
    'buffer',
    'eof',
    'disabled',
    'seek',
    'background',
    'account',
    'other-target',
  ]) {
    testWidgets('real player preparation and accepted switch: $transition', (
      tester,
    ) async {
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
        'yingyu.next.prepare.v1': transition != 'disabled',
      });
      final store = AppStore(await SharedPreferences.getInstance());
      // Set the actual persisted key through the public preference API below.
      final calls = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          final path = r.url.path;
          if (path.endsWith('/Episodes')) {
            return page([episode(1), episode(2), episode(3)]);
          }
          if (path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (path.contains('Sessions/Playing')) return response('', 204);
          final id = path.split('/').last;
          calls.add(id);
          final n = int.tryParse(id.split('-e').last) ?? 1;
          return response(
            jsonEncode({
              ...episode(n).data,
              'UserData': {'PlaybackPositionTicks': 0},
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final sessions = <PlaybackSession>[], backends = <FakeBackend>[];
      PlaybackSession create(MediaItem media) {
        final backend = FakeBackend()..gate.complete();
        backends.add(backend);
        final session = PlaybackSession(
          api: api,
          store: store,
          item: media,
          backend: backend,
        );
        sessions.add(session);
        return session;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            createSession: () => create(episode(1)),
            createSessionForItem: create,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(PlayerPage));
      final backend = backends.first;
      void emit({
        bool playing = true,
        bool buffering = false,
        bool completed = false,
      }) {
        backend.snapshot = PlaybackSnapshot(
          duration: const Duration(seconds: 780),
          position: const Duration(seconds: 778),
          playing: playing,
          buffering: buffering,
          completed: completed,
        );
        backend.updates.add(backend.snapshot);
      }

      emit();
      await tester.pumpAndSettle();
      expect(
        calls.where((id) => id == episode(2).id).length,
        transition == 'disabled' ? 0 : 1,
      );
      if (transition == 'pause') emit(playing: false);
      if (transition == 'buffer') emit(buffering: true);
      if (transition == 'eof') emit(playing: false, completed: true);
      if (transition == 'seek') {
        final seeking = sessions.first.seek(const Duration(seconds: 100));
        state.prepareNext();
        await seeking;
      }
      if (transition == 'background') {
        sessions.first.background = true;
        state.prepareNext();
        sessions.first.background = false;
      }
      if (transition == 'account') {
        api.session = syntheticSession();
        state.prepareNext();
      }
      await tester.pump();
      final target = episode(transition == 'other-target' ? 3 : 2);
      final switched = state.switchEpisode(target) as Future<void>;
      for (var n = 0; n < 30 && sessions.length < 2; n++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await switched;
      if (transition == 'account') {
        expect(sessions.length, 1);
      } else {
        expect(sessions.length, 2);
        expect(sessions.last.item.id, target.id);
        expect(
          calls.where((id) => id == target.id).length,
          ['seek', 'background'].contains(transition) ? 2 : 1,
        );
      }
      await tester.pumpWidget(const SizedBox());
      for (var n = 0; n < 25 && !backends.last.disposed; n++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      expect(tester.takeException(), isNull);
    });
  }
}
