import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/subtitle_position_memory.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'subtitle_memory102_test.dart' show ScopedRememberedBackend;

void main() {
  late AppStore store;
  late EmbyClient api;
  MediaItem detail = MediaItem({'Id': 'film', 'Type': 'Movie'});
  int detailRequests = 0, playbackRequests = 0;
  final sessions = <PlaybackSession>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    detailRequests = playbackRequests = 0;
    api = EmbyClient(
      client: MockClient((r) async {
        if (r.url.path.endsWith('PlaybackInfo')) {
          playbackRequests++;
          return response(jsonEncode(playbackData()), 200);
        }
        if (r.url.path.contains('Sessions/Playing')) return response('', 204);
        detailRequests++;
        return response(jsonEncode(detail.data), 200);
      }),
    )..session = syntheticSession();
  });
  tearDown(() async {
    for (final s in sessions) {
      s.ready = false;
      await s.close();
    }
    sessions.clear();
    api.close();
    store.log.dispose();
    store.dispose();
  });
  MediaItem film(String id) => MediaItem({'Id': id, 'Type': 'Movie'});
  MediaItem episode(
    String id, {
    String? season,
    String series = 'show',
    int? number,
  }) => MediaItem({
    'Id': id,
    'Type': 'Episode',
    'SeriesId': series,
    'SeasonId': ?season,
    'ParentIndexNumber': ?number,
  });
  PlaybackSession create(
    MediaItem item, {
    bool ready = true,
    bool phone = false,
    ScopedRememberedBackend? backend,
  }) {
    final s = PlaybackSession(
      api: api,
      store: store,
      item: item,
      backend: backend ?? ScopedRememberedBackend(),
    );
    s.configureSubtitleViewport(phone: phone);
    s.ready = ready;
    s.loading = !ready;
    sessions.add(s);
    return s;
  }

  double? initial(PlaybackSession s) =>
      (s.backend as ScopedRememberedBackend).initialPosition;
  test(
    'resource owner release cannot clear a newer owner or another film',
    () async {
      final memory = store.subtitlePositions;
      final a = SubtitlePositionTarget.resolve(api.session!, film('a'))!.key;
      final b = SubtitlePositionTarget.resolve(api.session!, film('b'))!.key;
      final old = memory.claim(SubtitleViewport.tablet, resource: a);
      final current = memory.claim(SubtitleViewport.tablet, resource: a);
      final other = memory.claim(SubtitleViewport.tablet, resource: b);
      memory.release(SubtitleViewport.tablet, old, resource: a);
      await memory.save(
        SubtitleViewport.tablet,
        current,
        25,
        active: () => true,
        resource: a,
      );
      memory.release(SubtitleViewport.tablet, current, resource: a);
      await memory.save(
        SubtitleViewport.tablet,
        current,
        80,
        active: () => true,
        resource: a,
      );
      await memory.save(
        SubtitleViewport.tablet,
        other,
        65,
        active: () => true,
        resource: b,
      );
      expect(memory.read(SubtitleViewport.tablet, resource: a), 25);
      expect(memory.read(SubtitleViewport.tablet, resource: b), 65);
    },
  );
  test('unidentified media never creates a shared catch-all position', () {
    expect(SubtitlePositionTarget.resolve(api.session!, MediaItem({})), isNull);
  });
  for (final phone in [false, true]) {
    test(
      'movies keep independent manual positions on ${phone ? 'phone' : 'tablet'}',
      () async {
        await create(film('a'), phone: phone).setSubtitlePosition(40);
        expect(initial(create(film('b'), phone: phone)), isNull);
        await create(film('b'), phone: phone).setSubtitlePosition(75);
        expect(initial(create(film('a'), phone: phone)), 40);
        expect(initial(create(film('b'), phone: phone)), 75);
      },
    );
  }
  test(
    'episodes share their season but never another season or show',
    () async {
      await create(episode('e1', season: 's1')).setSubtitlePosition(35);
      expect(initial(create(episode('e2', season: 's1'))), 35);
      expect(initial(create(episode('e3', season: 's2'))), isNull);
      await create(episode('e3', season: 's2')).setSubtitlePosition(60);
      expect(initial(create(episode('e4', season: 's1'))), 35);
      expect(
        initial(create(episode('e5', season: 'other-s1', series: 'other'))),
        isNull,
      );
    },
  );
  test(
    'series and season number can group a season when SeasonId is omitted',
    () async {
      await create(episode('e1', number: 0)).setSubtitlePosition(25);
      expect(initial(create(episode('e2', number: 0))), 25);
      expect(initial(create(episode('e3', number: 1))), isNull);
      expect(
        initial(create(episode('e4', series: 'other', number: 0))),
        isNull,
      );
    },
  );
  test(
    'unknown season stays on the individual episode and never groups by a guessed zero',
    () async {
      await create(episode('e1')).setSubtitlePosition(20);
      expect(initial(create(episode('e1'))), 20);
      expect(initial(create(episode('e2'))), isNull);
      expect(initial(create(episode('e3', number: 0))), isNull);
    },
  );
  test(
    'original disc placement is adjustable and remembered only for its movie',
    () async {
      final b = ScopedRememberedBackend()
        ..scope = SubtitlePositionScope.discEmbedded;
      final a = create(film('a'), backend: b);
      await a.setSubtitlePosition(0);
      final same = create(film('a')).backend as ScopedRememberedBackend;
      final other = create(film('b')).backend as ScopedRememberedBackend;
      expect(same.discInitial, 0);
      expect(same.initialPosition, isNull);
      expect(other.discInitial, isNull);
      same.scope = SubtitlePositionScope.discEmbedded;
      await sessions[sessions.length - 2].resetSubtitlePosition();
      expect(
        (create(film('a')).backend as ScopedRememberedBackend).discInitial,
        isNull,
      );
    },
  );
  test(
    'reset clears only the current season and current subtitle category',
    () async {
      final s = create(episode('e1', season: 's1'));
      await s.setSubtitlePosition(35);
      (s.backend as ScopedRememberedBackend).scope =
          SubtitlePositionScope.discEmbedded;
      await s.setSubtitlePosition(55);
      await create(episode('e2', season: 's2')).setSubtitlePosition(70);
      await create(episode('e3', season: 's1')).resetSubtitlePosition();
      final again =
          create(episode('e4', season: 's1')).backend
              as ScopedRememberedBackend;
      expect(again.initialPosition, isNull);
      expect(again.discInitial, 55);
      expect(initial(create(episode('e5', season: 's2'))), 70);
    },
  );
  test(
    'fresh detail resolves season memory before backend.open without another media request',
    () async {
      await create(episode('e1', season: 's1')).setSubtitlePosition(40);
      await create(episode('e2', season: 's2')).setSubtitlePosition(70);
      detail = episode('e3', season: 's1');
      final b = ScopedRememberedBackend()..gate.complete();
      final s = create(MediaItem({'Id': 'e3'}), ready: false, backend: b);
      await s.open();
      expect(b.initialPosition, 40);
      expect(s.subtitlePositionMemoryLabel, '本季');
      expect(s.ready, true);
      expect(detailRequests, 1);
      expect(playbackRequests, 1);
    },
  );
  test(
    'legacy global position is kept but cannot be applied to every new movie',
    () async {
      final memory = store.subtitlePositions;
      final owner = memory.claim(SubtitleViewport.tablet);
      await memory.save(SubtitleViewport.tablet, owner, 80, active: () => true);
      expect(initial(create(film('a'))), isNull);
      expect(initial(create(episode('e1', season: 's1'))), isNull);
      expect(memory.read(SubtitleViewport.tablet), 80);
    },
  );
  test(
    'same media id is isolated by account and server while token refresh keeps memory',
    () async {
      await create(film('a')).setSubtitlePosition(30);
      final first = api.session!;
      api.session = Session(
        base: first.base,
        userId: 'different',
        token: 'fake',
        username: 'fake',
        deviceId: 'fake',
      );
      expect(initial(create(film('a'))), isNull);
      api.session = Session(
        base: Uri.parse('https://other.invalid'),
        userId: first.userId,
        token: 'fake',
        username: 'fake',
        deviceId: 'fake',
      );
      expect(initial(create(film('a'))), isNull);
      api.session = Session(
        base: first.base,
        userId: first.userId,
        token: 'refreshed',
        username: first.username,
        deviceId: first.deviceId,
      );
      expect(initial(create(film('a'))), 30);
    },
  );
}
