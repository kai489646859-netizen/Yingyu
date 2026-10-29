import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/background_work.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/core/personal_sync.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession;

MediaItem personalMovie(
  String id, {
  bool favorite = false,
  bool played = false,
}) => MediaItem({
  'Id': id,
  'Type': 'Movie',
  'Name': '合成影片 $id',
  'ProviderIds': {'Tmdb': '26'},
  'UserData': {
    'IsFavorite': favorite,
    'Played': played,
    'PlaybackPositionTicks': 600000000,
    'PlayCount': 2,
  },
});

class PersonalServer {
  final entries = <String, MediaItem>{};
  final ratings = <String, bool>{};
  final requests = <http.Request>[];
  int failure = 0;
  Completer<void>? gate;
  bool repeatPage = false, incomplete = false, rejectWrite = false;
  http.Response response(Object data, [int status = 200]) => http.Response(
    jsonEncode(data),
    status,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  Future<http.Response> call(http.Request request) async {
    requests.add(request);
    await gate?.future;
    if (failure != 0) {
      return response({'Message': 'synthetic refusal'}, failure);
    }
    final path = request.url.path, query = request.url.queryParameters;
    expect(path, startsWith('/proxy/emby/Users/synthetic-user/'));
    expect(
      path.contains('PlaybackInfo') ||
          path.contains('/Videos/') ||
          path.contains('UserData'),
      false,
    );
    final parts = request.url.pathSegments;
    var id = parts.last;
    if (path.endsWith('/Rating')) id = parts[parts.length - 2];
    if (request.method != 'GET') {
      expect(request.body, isEmpty);
      var item = entries[id] ?? personalMovie(id);
      final user = object(item.data['UserData']);
      if (!rejectWrite) {
        if (path.contains('/FavoriteItems/')) {
          user['IsFavorite'] = request.method == 'POST';
        }
        if (path.contains('/PlayedItems/')) {
          user['Played'] = request.method == 'POST';
          user['PlaybackPositionTicks'] = 0;
        }
        if (path.endsWith('/Rating')) {
          if (request.method == 'DELETE') {
            ratings.remove(id);
          } else {
            ratings[id] = query['Likes'] == 'true';
          }
        }
      }
      item = MediaItem({...item.data, 'UserData': user});
      entries[id] = item;
      return response(user);
    }
    if (path.endsWith('/Items')) {
      var values = entries.values.where((item) {
        if (query['Ids'] != null && item.id != query['Ids']) return false;
        final user = object(item.data['UserData']);
        return switch (query['Filters']) {
          'IsFavorite' => user['IsFavorite'] == true,
          'IsPlayed' => user['Played'] == true,
          'IsUnplayed' => user['Played'] != true,
          'Likes' => ratings[item.id] == true,
          'Dislikes' => ratings[item.id] == false,
          _ => true,
        };
      }).toList();
      final total = values.length;
      values = values
          .skip(repeatPage ? 0 : int.parse(query['StartIndex'] ?? '0'))
          .take(int.parse(query['Limit'] ?? '100'))
          .toList();
      return response({
        'Items': values.map((v) => v.data).toList(),
        if (!incomplete) 'TotalRecordCount': total,
      });
    }
    return response((entries[id] ?? personalMovie(id)).data);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late PersonalServer server;
  late EmbyClient api;
  late PersonalSync sync;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    server = PersonalServer();
    api = EmbyClient(client: MockClient(server.call))
      ..session = syntheticSession();
    sync = PersonalSync(api, store.personal, store: store);
  });
  tearDown(() async {
    sync.dispose();
    api.close();
    await store.log.flush();
    store.dispose();
  });

  test(
    'favorite add and remove use dedicated endpoints and preserve progress and want list',
    () async {
      final item = personalMovie('a');
      server.entries['a'] = item;
      await store.personal.setSaved(
        sync.account,
        SavedList.watchlist,
        item,
        true,
      );
      await sync.setFavorite(item, true);
      expect(sync.favorite(item), true);
      expect(server.entries['a']!.resume, item.resume);
      await sync.setFavorite(item, false);
      expect(sync.favorite(item), false);
      expect(
        store.personal.contains(sync.account, SavedList.watchlist, 'a'),
        true,
      );
      expect(server.requests.map((r) => r.method), ['POST', 'DELETE']);
      expect(
        server.requests.every((r) => r.url.path.endsWith('/FavoriteItems/a')),
        true,
      );
    },
  );
  test(
    'legacy favorite migration is acknowledged once and server removal is not resurrected',
    () async {
      await store.personal.setSaved(
        sync.account,
        SavedList.favorites,
        personalMovie('local'),
        true,
      );
      await store.personal.setSaved(
        sync.account,
        SavedList.favorites,
        personalMovie('shared'),
        true,
      );
      server.entries['shared'] = personalMovie('shared', favorite: true);
      await sync.refreshFavorites();
      expect(
        server.requests
            .where((r) => r.method == 'POST')
            .map((r) => r.url.path.split('/').last),
        ['local'],
      );
      server.entries['local'] = personalMovie('local');
      await sync.refreshFavorites();
      expect(
        store.personal
            .items(sync.account, SavedList.favorites)
            .map((v) => v.id),
        ['shared'],
      );
      expect(server.requests.where((r) => r.method == 'POST').length, 1);
    },
  );
  test(
    'favorites read every page without dropping entries and preserve concrete IDs with same TMDB',
    () async {
      for (var i = 0; i < 211; i++) {
        server.entries['$i'] = personalMovie('$i', favorite: true);
      }
      await sync.refreshFavorites();
      expect(
        store.personal.items(sync.account, SavedList.favorites).length,
        211,
      );
      expect(server.requests.map((r) => r.url.queryParameters['StartIndex']), [
        '0',
        '100',
        '200',
      ]);
      expect(server.requests.every((r) => r.method == 'GET'), true);
    },
  );
  for (final mode in ['repeat', 'missing total', 'forbidden']) {
    test(
      'incomplete favorite snapshot preserves prior saved favorites $mode',
      () async {
        await store.personal.acknowledgeFavorite(
          sync.account,
          personalMovie('prior', favorite: true),
          true,
        );
        for (var i = 0; i < 201; i++) {
          server.entries['$i'] = personalMovie('$i', favorite: true);
        }
        server.repeatPage = mode == 'repeat';
        server.incomplete = mode == 'missing total';
        server.failure = mode == 'forbidden' ? 403 : 0;
        await expectLater(sync.refreshFavorites(), throwsA(isA<AppFailure>()));
        expect(
          store.personal.contains(sync.account, SavedList.favorites, 'prior'),
          true,
        );
      },
    );
  }
  test(
    'failed or unacknowledged favorite mutation never displays fake success',
    () async {
      final item = personalMovie('a');
      server.entries['a'] = item;
      server.rejectWrite = true;
      await expectLater(
        sync.setFavorite(item, true),
        throwsA(isA<AppFailure>()),
      );
      expect(
        store.personal.contains(sync.account, SavedList.favorites, 'a'),
        false,
      );
      server.failure = 403;
      await expectLater(
        sync.setFavorite(item, true),
        throwsA(isA<AppFailure>()),
      );
      expect(sync.favorite(item), false);
    },
  );
  test(
    'concurrent presses do not duplicate writes and late account response cannot be published',
    () async {
      server.gate = Completer<void>();
      final pending = sync.setFavorite(personalMovie('a'), true);
      await expectLater(
        sync.setFavorite(personalMovie('a'), true),
        throwsA(isA<AppFailure>()),
      );
      api.session = Session(
        base: sync.account.base,
        userId: 'other',
        token: 'other',
        username: 'other',
        deviceId: 'test',
      );
      server.gate!.complete();
      await expectLater(pending, throwsA(isA<AppFailure>()));
      expect(server.requests.length, 1);
      expect(store.personal.items(api.session!, SavedList.favorites), isEmpty);
      expect(store.personal.items(sync.account, SavedList.favorites), isEmpty);
    },
  );
  test(
    'likes, dislikes and clearing are read back with official filters without numerical rating guesses',
    () async {
      final item = personalMovie('a', favorite: true);
      server.entries['a'] = item;
      for (final value in <bool?>[true, false, null]) {
        await sync.setRating(item, value);
        expect(sync.ratings['a'], value);
        expect(server.entries['a']!.resume, item.resume);
        expect(
          object(server.entries['a']!.data['UserData'])['IsFavorite'],
          true,
        );
      }
      final writes = server.requests.where((r) => r.method != 'GET').toList();
      expect(writes.map((r) => r.method), ['POST', 'POST', 'DELETE']);
      expect(writes.map((r) => r.url.queryParameters['Likes']), [
        'true',
        'false',
        null,
      ]);
      expect(
        server.requests
            .where((r) => r.method == 'GET')
            .every((r) => r.url.queryParameters['Ids'] == 'a'),
        true,
      );
    },
  );
  test(
    'read personal list types select server filters without media access',
    () async {
      server.entries['a'] = personalMovie('a', favorite: true, played: true);
      server.ratings['a'] = true;
      for (final list in PersonalList.values) {
        await sync.page(list);
      }
      expect(
        server.requests.map((r) => r.url.queryParameters['Filters']),
        PersonalList.values.map((v) => v.filter),
      );
      expect(server.requests.every((r) => r.method == 'GET'), true);
    },
  );
  test(
    'manual watched states reject pending progress and pending completion without losing either',
    () async {
      final item = personalMovie('a');
      await store.saveProgress(
        sync.account,
        'a',
        const Duration(seconds: 90),
        serverBaseline: item,
      );
      await expectLater(
        sync.setPlayed(item, false),
        throwsA(isA<AppFailure>()),
      );
      expect(
        store.localProgress(sync.account, 'a'),
        const Duration(seconds: 90),
      );
      final other = personalMovie('b');
      await store.completions.remember(
        sync.account,
        other,
        const Duration(minutes: 90),
      );
      await expectLater(
        sync.setPlayed(other, false),
        throwsA(isA<AppFailure>()),
      );
      expect(store.completions.pending(sync.account, 'b'), true);
      expect(server.requests, isEmpty);
    },
  );
  test(
    'manual played and unplayed use one concrete item and preserve favorites',
    () async {
      final item = personalMovie('a', favorite: true);
      server.entries['a'] = item;
      await sync.setPlayed(item, true);
      expect(object(sync.latest(item).data['UserData'])['Played'], true);
      await sync.setPlayed(item, false);
      expect(object(sync.latest(item).data['UserData'])['Played'], false);
      expect(object(sync.latest(item).data['UserData'])['IsFavorite'], true);
      expect(server.requests.map((r) => r.method), ['POST', 'DELETE']);
      expect(
        server.requests.every((r) => r.url.path.endsWith('/PlayedItems/a')),
        true,
      );
      await expectLater(
        sync.setPlayed(MediaItem({'Id': 'series', 'Type': 'Series'}), true),
        throwsA(isA<AppFailure>()),
      );
      expect(server.requests.length, 2);
    },
  );
  test(
    'confirmed local completion is retired after explicit unplayed, never after unrelated favorite',
    () async {
      final item = personalMovie('a', played: true);
      server.entries['a'] = item;
      await store.completions.remember(
        sync.account,
        item,
        const Duration(minutes: 90),
      );
      final key = store.completions.key(sync.account, 'a');
      await store.prefs.setString(
        key,
        jsonEncode({
          ...store.completions.receipt(sync.account, 'a')!,
          'confirmed': true,
        }),
      );
      await sync.setFavorite(item, true);
      expect(store.completions.receipt(sync.account, 'a'), isNotNull);
      await sync.setPlayed(item, false);
      expect(store.completions.receipt(sync.account, 'a'), isNull);
    },
  );
  test(
    'pausing and leaving favorites stops optional migration, retaining local unsynced choices',
    () async {
      final item = personalMovie('a');
      await store.personal.setSaved(
        sync.account,
        SavedList.favorites,
        item,
        true,
      );
      await sync.refreshFavorites(allowed: () => false);
      expect(server.requests, isEmpty);
      expect(store.personal.unsyncedFavorites(sync.account).single.id, 'a');
      api.backgroundWork.pause('test', true);
      await expectLater(
        sync.setFavorite(item, false),
        throwsA(isA<AppFailure>()),
      );
      expect(server.requests, isEmpty);
    },
  );
  test(
    'personal edits wait for older playback repair before writing favorite state',
    () async {
      sync.dispose();
      final gate = Completer<void>();
      sync = PersonalSync(
        api,
        store.personal,
        waitForPlaybackSync: () => gate.future,
      );
      final write = sync.setFavorite(personalMovie('a'), true);
      await Future<void>.delayed(Duration.zero);
      expect(sync.busy, true);
      expect(server.requests, isEmpty);
      gate.complete();
      await write;
      expect(server.requests.single.url.path, endsWith('/FavoriteItems/a'));
      expect(sync.favorite(personalMovie('a')), true);
    },
  );

  test(
    'personal reads share optional-work cancellation while explicit writes stay outside',
    () async {
      sync.dispose();
      api.close();
      api = EmbyClient(
        client: MockClient((request) async {
          expect(
            BackgroundWork.current,
            request.method == 'GET' ? same(api.backgroundWork) : isNull,
          );
          return server.call(request);
        }),
      )..session = syntheticSession();
      sync = PersonalSync(api, store.personal);
      server.entries['a'] = personalMovie('a');
      await sync.page(PersonalList.unplayed);
      await sync.setRating(personalMovie('a'), true);
      await sync.refreshStatus(personalMovie('a'));
      expect(server.requests.where((r) => r.method == 'POST').length, 1);
      expect(sync.ratings['a'], true);
    },
  );
}
