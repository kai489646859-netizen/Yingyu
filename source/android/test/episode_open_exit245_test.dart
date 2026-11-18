import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/watch_progress.dart';

import 'core_test.dart' show playbackData, response, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class ParsedRuntimeBackend extends FakeBackend implements OpeningStartBackend {
  ParsedRuntimeBackend(this.runtime) {
    gate.complete();
  }

  final Duration runtime;
  @override
  Duration Function(Duration)? resolveOpeningStart;

  @override
  Future<void> open(PlaybackRoute route, Duration start) =>
      super.open(route, resolveOpeningStart?.call(runtime) ?? start);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtime = Duration(milliseconds: 1377407);
  const shortViewing = Duration(milliseconds: 4609);
  late AppStore store;
  late EmbyClient api;
  late FakeBackend backend;
  late PlaybackSession player;
  late Duration duration, position;
  late bool played, falseCompletionOnStop;
  late int userDataWrites;
  late Json catalog;

  MediaItem detail() => MediaItem({
    'Id': 'episode',
    'Type': 'Episode',
    if (duration > Duration.zero) 'RunTimeTicks': ticks(duration),
    'UserData': {
      'PlaybackPositionTicks': ticks(position),
      'Played': played,
      'PlayCount': 1,
      'IsFavorite': true,
    },
  });

  void createPlayer() {
    player = PlaybackSession(
      api: api,
      store: store,
      backend: backend,
      item: MediaItem(catalog),
    );
    addTearDown(() async {
      await player.close();
      player.dispose();
      api.close();
      store.log.dispose();
      store.dispose();
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    duration = position = Duration.zero;
    played = falseCompletionOnStop = false;
    userDataWrites = 0;
    catalog = {
      'Id': 'episode',
      'Type': 'Episode',
      'SeriesId': 'series',
      'SeasonId': 'season',
    };
    backend = FakeBackend()..gate.complete();
    api = EmbyClient(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (path.endsWith('/Stopped')) {
          final body = object(jsonDecode(request.body));
          position = falseCompletionOnStop
              ? Duration.zero
              : fromTicks(body['PositionTicks']);
          if (falseCompletionOnStop) played = true;
          return response('', 204);
        }
        if (path.contains('/Sessions/Playing')) return response('', 204);
        if (path.endsWith('/UserData')) {
          userDataWrites++;
          final body = object(jsonDecode(request.body));
          expect(body['IsFavorite'], true);
          position = fromTicks(body['PlaybackPositionTicks']);
          played = body['Played'] == true;
          return response('', 204);
        }
        return response(jsonEncode(detail().data), 200);
      }),
    )..session = syntheticSession();
  });

  for (final previous in [false, true]) {
    test(
      'a short exit repairs a false stop completion; previous played=$previous',
      () async {
        played = previous;
        falseCompletionOnStop = true;
        createPlayer();
        await player.open();
        backend.snapshot = const PlaybackSnapshot(
          position: shortViewing,
          duration: runtime,
          playing: true,
        );
        backend.updates.add(backend.snapshot);
        await Future<void>.delayed(Duration.zero);
        await player.close();
        expect(player.completed, false);
        expect(played, previous);
        expect(position, shortViewing);
        expect(userDataWrites, 1);
        final view = WatchProgressState.resolve(
          detail(),
          api.session,
          store,
          showCompletionWithoutDuration: true,
        );
        expect(view.completed, false);
        expect(view.label, contains('00:04'));
      },
    );
  }

  test('a server completion near the end is preserved', () async {
    falseCompletionOnStop = true;
    createPlayer();
    await player.open();
    backend.snapshot = const PlaybackSnapshot(
      position: Duration(minutes: 22),
      duration: runtime,
      playing: true,
    );
    backend.updates.add(backend.snapshot);
    await Future<void>.delayed(Duration.zero);
    await player.close();
    expect(played, true);
  });

  test(
    'an opening checkpoint beyond the episode length starts at zero',
    () async {
      duration = runtime;
      position = const Duration(milliseconds: 2122954);
      createPlayer();
      await player.open();
      expect(backend.initial, Duration.zero);
      expect(player.completed, false);
    },
  );

  test(
    'automatic next uses season rule and catalog length on its first open',
    () async {
      catalog['RunTimeTicks'] = ticks(runtime);
      createPlayer();
      await store.personal.setSkipRule(
        player.account,
        MediaItem(catalog),
        SkipScope.season,
        const SkipRule(
          intro: IntroRange(Duration(seconds: 12), Duration(seconds: 75)),
          autoIntro: true,
        ),
        runtime,
      );
      player.skipOpeningIntro = true;
      await player.open();
      expect(backend.initial, const Duration(seconds: 75));
    },
  );

  test(
    'automatic next can use parsed runtime when the server has none',
    () async {
      backend = ParsedRuntimeBackend(runtime);
      createPlayer();
      await store.personal.setSkipRule(
        player.account,
        MediaItem(catalog),
        SkipScope.season,
        const SkipRule(
          intro: IntroRange(Duration(seconds: 12), Duration(seconds: 75)),
          autoIntro: true,
        ),
        runtime,
      );
      player.skipOpeningIntro = true;
      await player.open();
      expect(backend.initial, const Duration(seconds: 75));
      expect(player.openingIntro?.from, Duration.zero);
    },
  );
}
