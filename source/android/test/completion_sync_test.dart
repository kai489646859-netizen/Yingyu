import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/server_connection.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/connection_notice.dart';
import 'package:yingyu/ui/watch_progress.dart';
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
  test(
    'failed completed write survives app restart and retries each episode separately',
    () async {
      await store.completions.remember(
        account,
        film(),
        const Duration(minutes: 10),
      );
      online = false;
      await store.completions.retry(api, account);
      expect(store.completions.pending(account, 'ep'), true);
      final reopened = AppStore(await SharedPreferences.getInstance());
      expect(reopened.completions.pending(account, 'ep'), true);
      online = true;
      await reopened.completions.retry(api, account);
      expect(played, true);
      expect(reopened.completions.pending(account, 'ep'), false);
      await reopened.completions.retry(api, account);
      expect(calls.where((c) => c.contains('PlayedItems/')).length, 1);
      reopened.log.dispose();
      reopened.dispose();
    },
  );
  test('200 without Played readback retains receipt', () async {
    persist = false;
    await store.completions.remember(
      account,
      film(),
      const Duration(minutes: 10),
    );
    await store.completions.retry(api, account);
    expect(store.completions.pending(account, 'ep'), true);
  });
  test('already watched server is not marked twice', () async {
    await store.completions.remember(
      account,
      film(),
      const Duration(minutes: 10),
    );
    played = true;
    await store.completions.retry(api, account);
    expect(calls.where((c) => c.contains('PlayedItems/')), isEmpty);
    expect(store.completions.pending(account, 'ep'), false);
  });
  test(
    'conflicted completed episodes do not starve later pending episodes',
    () async {
      for (var i = 0; i < 3; i++) {
        await store.completions.remember(
          account,
          MediaItem({...film().data, 'Id': 'ep$i'}),
          const Duration(minutes: 10),
        );
      }
      final separate = EmbyClient(
        client: MockClient((request) async {
          final id = request.url.path.split('/').last;
          return response(
            jsonEncode({
              ...film().data,
              'Id': id,
              'UserData': {
                'Played': id == 'ep2',
                'PlaybackPositionTicks': ticks(const Duration(seconds: 20)),
                'LastPlayedDate': '2999-01-01T00:00:00Z',
              },
            }),
            200,
          );
        }),
      )..session = account;
      await store.completions.retry(separate, account);
      expect(store.completions.pending(account, 'ep2'), true);
      await store.completions.retry(separate, account);
      expect(store.completions.pending(account, 'ep2'), false);
      expect(store.completions.pending(account, 'ep0'), true);
      expect(store.completions.pending(account, 'ep1'), true);
      separate.close();
    },
  );
  test(
    'conflicted partial episodes do not starve later pending positions',
    () async {
      for (var i = 0; i < 3; i++) {
        await store.saveProgress(
          account,
          'ep$i',
          const Duration(seconds: 125),
          serverBaseline: MediaItem({...film().data, 'Id': 'ep$i'}),
        );
      }
      final separate = EmbyClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          final id = request.url.path.split('/').last;
          return response(
            jsonEncode({
              ...film().data,
              'Id': id,
              'UserData': {
                'Played': false,
                'PlaybackPositionTicks': ticks(
                  Duration(seconds: id == 'ep2' ? 125 : 20),
                ),
              },
            }),
            200,
          );
        }),
      )..session = account;
      await store.retryPendingProgress(separate, account);
      expect(store.localProgress(account, 'ep2'), isNotNull);
      await store.retryPendingProgress(separate, account);
      expect(store.localProgress(account, 'ep2'), isNull);
      expect(store.localProgress(account, 'ep0'), isNotNull);
      expect(store.localProgress(account, 'ep1'), isNotNull);
      separate.close();
    },
  );
  test('wrong account cannot transmit or acknowledge old records', () async {
    await store.completions.remember(
      account,
      film(),
      const Duration(minutes: 10),
    );
    final other = syntheticSession('http://127.0.0.1:10');
    api.session = other;
    await store.completions.retry(api, account);
    await store.completions.retry(api, other);
    expect(calls, isEmpty);
    expect(store.completions.pending(account, 'ep'), true);
    expect(store.completions.pending(other, 'ep'), false);
  });
  test('retry pauses before next receipt when playback starts', () async {
    await store.completions.remember(
      account,
      film(),
      const Duration(minutes: 10),
    );
    await store.completions.retry(api, account, allowed: () => false);
    expect(calls, isEmpty);
  });
  test(
    'partial departing episode retries after reconnect without marking completed',
    () async {
      final baseline = film();
      await store.saveProgress(
        account,
        'ep',
        const Duration(seconds: 125),
        serverBaseline: baseline,
      );
      online = false;
      await store.retryPendingProgress(api, account);
      expect(store.localProgress(account, 'ep'), const Duration(seconds: 125));
      online = true;
      await store.retryPendingProgress(api, account);
      expect(position, 125000);
      expect(played, false);
      expect(store.localProgress(account, 'ep'), isNull);
      expect(calls.where((c) => c.contains('PlayedItems/')), isEmpty);
    },
  );
  test(
    'pending partial retry does not overwrite another device newer observation',
    () async {
      await store.saveProgress(
        account,
        'ep',
        const Duration(seconds: 125),
        serverBaseline: film(),
      );
      position = 20000;
      await store.retryPendingProgress(api, account);
      expect(position, 20000);
      expect(store.localProgress(account, 'ep'), const Duration(seconds: 125));
      expect(calls.where((c) => c.endsWith('/UserData')), isEmpty);
    },
  );
  test('completion is not created by opening or partial playback', () async {
    final backend = FakeBackend()..gate.complete();
    final session = PlaybackSession(
      api: api,
      store: store,
      item: film(),
      backend: backend,
    );
    await session.open();
    await session.seek(const Duration(seconds: 20));
    await session.close();
    session.dispose();
    expect(store.completions.receipt(account, 'ep'), isNull);
    expect(calls.where((c) => c.contains('PlayedItems/')), isEmpty);
  });
  testWidgets(
    'details use durable pending position and truthful completed bar',
    (tester) async {
      position = 60000;
      final entry = film();
      await store.saveProgress(
        account,
        'ep',
        const Duration(seconds: 125),
        serverBaseline: entry,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WatchProgress(item: entry, account: account, store: store),
          ),
        ),
      );
      expect(find.text('看到 02:05 / 10:00 · 待同步 Emby'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        closeTo(125 / 600, .0001),
      );
      await store.completions.remember(
        account,
        entry,
        const Duration(minutes: 10),
      );
      await store.saveProgress(
        account,
        'ep',
        Duration.zero,
        serverBaseline: entry,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WatchProgress(item: entry, account: account, store: store),
          ),
        ),
      );
      expect(find.text('已看完 · 待同步 Emby'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        1,
      );
    },
  );
  testWidgets(
    'disconnect expires despite repeated failures and recovery displays once',
    (tester) async {
      final connection = ServerConnection();
      await tester.pumpWidget(
        MaterialApp(home: PlaybackConnectionNotice(connection: connection)),
      );
      connection.finish(
        connection.begin(),
        ServerStatus.disconnected,
        reason: 'first',
      );
      await tester.pump();
      expect(find.text('Emby 服务器连接已断开'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      connection.finish(
        connection.begin(),
        ServerStatus.disconnected,
        reason: 'again',
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('playback-connection-notice')), findsNothing);
      connection.finish(connection.begin(), ServerStatus.connected);
      await tester.pump();
      expect(find.text('Emby 服务器已连接'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      connection.finish(connection.begin(), ServerStatus.connected);
      await tester.pump();
      expect(find.byKey(const Key('playback-connection-notice')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      connection.dispose();
    },
  );
}
