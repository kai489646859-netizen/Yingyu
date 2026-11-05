import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/episode_neighbors.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem ep(int s, int e) => MediaItem({
  'Id': 's$s-e$e',
  'Type': 'Episode',
  'SeriesId': 'show',
  'SeasonId': 's$s',
  'ParentIndexNumber': s,
  'IndexNumber': e,
});
MediaItem season(int s) => MediaItem({
  'Id': 's$s',
  'Type': 'Season',
  'SeriesId': 'show',
  'IndexNumber': s,
});
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EmbyClient api;
  late BrowseRepository browse;
  late List<Uri> calls;
  late Map<String, List<MediaItem>> remote;
  Completer<void>? gate;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    calls = [];
    gate = null;
    remote = {
      'adjacent': [ep(1, 1), ep(1, 2)],
      'seasons': [season(3), season(1), season(2)],
      's2': [ep(2, 1)],
    };
    api = EmbyClient(
      client: MockClient((r) async {
        calls.add(r.url);
        if (gate != null) await gate!.future;
        final key = r.url.path.endsWith('/Seasons')
            ? 'seasons'
            : r.url.queryParameters['SeasonId'] ?? 'adjacent';
        final values = remote[key];
        if (values == null) return response('failed', 500);
        return response(
          jsonEncode({
            'Items': values.map((e) => e.data).toList(),
            'TotalRecordCount': values.length,
          }),
          200,
        );
      }),
    )..session = syntheticSession();
    browse = BrowseRepository(
      api,
      BrowseCache(prefs),
      BrowsePreferences(prefs),
    );
  });
  tearDown(() {
    browse.dispose();
    api.close();
  });
  Future<void> cache(String key, List<MediaItem> items, {int? total}) =>
      browse.cache.put(
        browse.key(key),
        ItemPage(items, total ?? items.length),
        DateTime.now(),
      );
  Future<void> episodes(int s, List<MediaItem> items, {int? total}) => cache(
    BrowseRepository.episodeCatalogueKey('show', 's$s'),
    items,
    total: total,
  );
  Future<EpisodeNeighbors> load(
    MediaItem current, {
    bool Function()? allowed,
  }) => EpisodeNeighbors.load(api, current, browse: browse, allowed: allowed);

  test('complete local same-season catalogue makes zero requests', () async {
    await episodes(1, [ep(1, 3), ep(1, 1), ep(1, 2)]);
    final value = await load(ep(1, 2));
    expect(value.previous?.id, 's1-e1');
    expect(value.next?.id, 's1-e3');
    expect(calls, isEmpty);
  });
  test('local season finale crosses numerically with zero requests', () async {
    await episodes(1, [ep(1, 1), ep(1, 2)]);
    await cache('seasons:show', [season(20), season(2), season(1)]);
    await episodes(2, [ep(2, 2), ep(2, 1)]);
    final value = await load(ep(1, 2));
    expect(value.next?.id, 's2-e1');
    expect(calls, isEmpty);
  });
  test('cache miss only fetches missing next season boundary', () async {
    await episodes(1, [ep(1, 1), ep(1, 2)]);
    await cache('seasons:show', [season(1), season(2)]);
    expect((await load(ep(1, 2))).next?.id, 's2-e1');
    expect(calls.length, 1);
    expect(calls.single.queryParameters['SeasonId'], 's2');
    expect(calls.single.queryParameters['Limit'], '1');
  });
  test(
    'missing local seasons falls back to seasons then first episode only',
    () async {
      await episodes(1, [ep(1, 1), ep(1, 2)]);
      expect((await load(ep(1, 2))).next?.id, 's2-e1');
      expect(calls.length, 2);
      expect(calls.first.path, endsWith('/Seasons'));
      expect(calls.last.queryParameters['SeasonId'], 's2');
      expect(
        calls.every(
          (uri) =>
              !uri.path.contains('/Items/') &&
              !uri.path.contains('PlaybackInfo') &&
              !uri.path.contains('stream'),
        ),
        true,
      );
    },
  );
  test(
    'server incorrect cross-season adjacent is checked by season number',
    () async {
      remote['adjacent'] = [ep(1, 1), ep(1, 2), ep(20, 1)];
      expect((await load(ep(1, 2))).next?.id, 's2-e1');
      expect(calls.length, 3);
    },
  );
  test(
    'fetched boundary metadata is reused locally on the next lookup',
    () async {
      await episodes(1, [ep(1, 1), ep(1, 2)]);
      expect((await load(ep(1, 2))).next?.id, 's2-e1');
      expect(calls.length, 2);
      calls.clear();
      expect((await load(ep(1, 2))).next?.id, 's2-e1');
      expect(calls, isEmpty);
    },
  );
  test('partial local catalogue is not mistaken for season end', () async {
    await episodes(1, [ep(1, 1)], total: 20);
    expect((await load(ep(1, 1))).next?.id, 's1-e2');
    expect(calls.length, 1);
    expect(calls.single.queryParameters['AdjacentTo'], 's1-e1');
  });
  for (final kind in [
    'last-season',
    'missing-season',
    'missing-first',
    'duplicate-season',
    'specials',
  ]) {
    test('does not invent or skip a target: $kind', () async {
      final s = kind == 'specials' ? 0 : 1;
      await episodes(s, [ep(s, 1), ep(s, 2)]);
      await cache(
        'seasons:show',
        kind == 'last-season'
            ? [season(1)]
            : kind == 'missing-season'
            ? [season(1), season(3)]
            : kind == 'duplicate-season'
            ? [season(1), season(2), season(2)]
            : [season(0), season(1), season(2)],
      );
      await episodes(2, kind == 'missing-first' ? [ep(2, 2)] : [ep(2, 1)]);
      expect((await load(ep(s, 2))).next, isNull);
      expect(calls, isEmpty);
    });
  }
  test('previous season remains available from cache', () async {
    await episodes(1, [ep(1, 1), ep(1, 2)]);
    await episodes(2, [ep(2, 1), ep(2, 2)]);
    await cache('seasons:show', [season(1), season(2)]);
    final value = await load(ep(2, 1));
    expect(value.previous?.id, 's1-e2');
    expect(value.next?.id, 's2-e2');
    expect(calls, isEmpty);
  });
  test('cancel after first response prevents subsequent requests', () async {
    var allowed = true;
    gate = Completer<void>();
    final future = load(ep(1, 2), allowed: () => allowed);
    final check = expectLater(future, throwsA(isA<AppFailure>()));
    await Future<void>.delayed(Duration.zero);
    allowed = false;
    gate!.complete();
    await check;
    expect(calls.length, 1);
  });
  test(
    'account change rejects late response without querying new account',
    () async {
      gate = Completer<void>();
      final future = load(ep(1, 2));
      final check = expectLater(future, throwsA(isA<AppFailure>()));
      await Future<void>.delayed(Duration.zero);
      api.session = syntheticSession();
      gate!.complete();
      await check;
      expect(calls.length, 1);
    },
  );
  test('server failure is not reported as whole-series completion', () async {
    await episodes(1, [ep(1, 1), ep(1, 2)]);
    remote.remove('seasons');
    final value = await load(ep(1, 2));
    expect(value.next, isNull);
    expect(value.previous?.id, 's1-e1');
    expect(value.warning, contains('跨季目录读取失败'));
  });
}
