import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'track_menu_test.dart' show MenuBackend;

class OpeningBackend extends MenuBackend implements OpeningTracksBackend {
  OpeningBackend({this.prepareTracksWhilePaused = true});
  @override
  final bool prepareTracksWhilePaused;
  final selecting = Completer<void>(), selected = Completer<void>();
  final settling = Completer<void>(), settled = Completer<void>();
  final calls = <String>[];
  @override
  Future<void> subtitle(TrackOption track) async {
    calls.add('select');
    if (!selecting.isCompleted) selecting.complete();
    await selected.future;
    await super.subtitle(track);
  }

  @override
  Future<void> settleOpeningTracks() async {
    calls.add('settle');
    settling.complete();
    await settled.future;
  }

  @override
  Future<void> play() async {
    calls.add('play');
    await super.play();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (hdr, interrupt) in [
    (true, 'none'),
    (false, 'none'),
    (true, 'background'),
    (true, 'close'),
    (true, 'failure'),
  ]) {
    test(
      'HDR=$hdr interruption=$interrupt initial selection and cache settle precede first play',
      () async {
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
        final backend = OpeningBackend(prepareTracksWhilePaused: hdr)
          ..gate.complete();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        final opening = session.open();
        addTearDown(() async {
          if (!backend.selected.isCompleted) backend.selected.complete();
          if (!backend.settled.isCompleted) backend.settled.complete();
          await opening;
          await session.close();
          api.close();
          await store.log.flush();
          store.log.dispose();
          store.dispose();
        });
        await backend.selecting.future;
        await Future<void>.delayed(Duration.zero);
        if (interrupt != 'none') {
          if (interrupt == 'background') await session.pauseForBackground();
          if (interrupt == 'close') unawaited(session.close());
          if (interrupt == 'failure') {
            backend.failures.add('合成真实播放失败');
            await Future<void>.delayed(Duration.zero);
          }
          backend.selected.complete();
          if (interrupt == 'background') {
            await backend.settling.future;
            backend.settled.complete();
          }
          await opening;
          expect(
            backend.plays,
            0,
            reason:
                'Opening cannot unpause a canceled/background/failed session',
          );
          return;
        }
        if (hdr) {
          expect(
            backend.plays,
            0,
            reason:
                'Automatic track selection must finish under the opening pause',
          );
          expect(session.loading, true);
          backend.selected.complete();
          await backend.settling.future;
          expect(backend.plays, 0);
          backend.settled.complete();
          await opening;
          expect(backend.calls, ['select', 'settle', 'play']);
        } else {
          await opening;
          expect(
            backend.plays,
            1,
            reason:
                'Existing compatible output keeps asynchronous optional subtitles',
          );
          expect(backend.calls, isNot(contains('settle')));
        }
      },
    );
  }
}
