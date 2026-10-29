import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  final account = syntheticSession();
  final calls = <String>[];
  bool online = true, played = false, persist = true;
  int position = 0;
  MediaItem film() => MediaItem({
    'Id': 'ep',
    'Name': '合成剧集',
    'Type': 'Episode',
    'SeriesId': 'series',
    'SeasonId': 's1',
    'IndexNumber': 8,
    'ParentIndexNumber': 1,
    'RunTimeTicks': ticks(const Duration(minutes: 10)),
    'UserData': {
      'Played': played,
      'PlaybackPositionTicks': position * 10000,
      'PlayCount': 1,
      'IsFavorite': false,
    },
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    calls.clear();
    online = true;
    played = false;
    persist = true;
    position = 0;
    api = EmbyClient(
      client: MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (!online) return response('{}', 503);
        if (request.url.queryParameters['Filters'] == 'IsPlayed') {
          return response(
            jsonEncode({
              'Items': [if (played) film().data],
              'TotalRecordCount': played ? 1 : 0,
            }),
            200,
          );
        }
        if (request.url.path.endsWith('PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (request.url.path.contains('Sessions/Playing')) {
          position =
              integer(jsonDecode(request.body)['PositionTicks']) ~/ 10000;
          return response('', 204);
        }
        if (request.url.path.contains('PlayedItems/')) {
          if (persist) {
            played = true;
            position = 0;
          }
          return response('{}', 200);
        }
        if (request.url.path.endsWith('/UserData') &&
            request.method == 'POST') {
          if (persist) {
            position =
                integer(jsonDecode(request.body)['PlaybackPositionTicks']) ~/
                10000;
          }
          return response('{}', 200);
        }
        return response(jsonEncode(film().data), 200);
      }),
    )..session = account;
  });
  tearDown(() {
    api.close();
    store.log.dispose();
    store.dispose();
  });
  test(
    'natural end sends Stopped and verifies Played immediately without leaving page',
    () async {
      final backend = FakeBackend()..gate.complete();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: film(),
        backend: backend,
      );
      await session.open();
      await session.seek(const Duration(seconds: 599));
      backend.snapshot = const PlaybackSnapshot(
        position: Duration(minutes: 10),
        duration: Duration(minutes: 10),
        completed: true,
      );
      backend.updates.add(backend.snapshot);
      await Future<void>.delayed(Duration.zero);
      await session.report('Progress');
      expect(played, true);
      expect(session.completed, true);
      expect((await api.personalItems('IsPlayed')).items.single.id, 'ep');
      expect(session.closed, false);
      expect(backend.disposed, false);
      expect(calls.where((c) => c.contains('PlayedItems/')).length, 1);
      expect(store.completions.pending(account, 'ep'), false);
      await session.report('Progress');
      await session.close();
      expect(calls.where((c) => c.endsWith('/Stopped')).length, 1);
      session.dispose();
    },
  );
}
