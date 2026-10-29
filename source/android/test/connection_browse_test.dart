import 'package:yingyu/ui/release_refresh.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/background_work.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/server_connection.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/settings.dart';
import 'core_test.dart' show response, syntheticSession;
import 'offline_settle.dart';

class AbortClient extends http.BaseClient {
  final started = Completer<void>();
  int aborted = 0, details = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.path.endsWith('/Items')) {
      started.complete();
      await (request as http.AbortableRequest).abortTrigger;
      aborted++;
      throw http.RequestAbortedException(request.url);
    }
    details++;
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"Id":"movie"}')),
      200,
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  test(
    'server outcomes distinguish disconnect, HTTP denial and recovery; old results cannot override recovery',
    () async {
      var mode = 0;
      final api = EmbyClient(
        client: MockClient((req) async {
          expect(req.url.path, '/proxy/emby/Users/synthetic-user');
          expect(req.method, 'GET');
          expect(req.followRedirects, false);
          if (mode == 1) throw http.ClientException('synthetic disconnect');
          return response(
            mode == 2 ? '{}' : '{"Id":"user-1"}',
            mode == 2
                ? 403
                : mode == 3
                ? 404
                : 200,
          );
        }),
      )..session = syntheticSession();
      await api.testConnection();
      expect(api.connection.status, ServerStatus.connected);
      mode = 1;
      await expectLater(api.testConnection(), throwsA(anything));
      expect(api.connection.status, ServerStatus.disconnected);
      mode = 2;
      await expectLater(api.testConnection(), throwsA(anything));
      expect(api.connection.status, ServerStatus.denied);
      final earlier = api.connection.begin();
      mode = 0;
      await api.testConnection();
      expect(api.connection.recovery, 1);
      api.connection.finish(earlier, ServerStatus.disconnected);
      expect(api.connection.status, ServerStatus.connected);
      mode = 3;
      await expectLater(api.testConnection(), throwsA(anything));
      expect(
        api.connection.hasProblem,
        false,
        reason: 'a missing resource is not a disconnected server',
      );
      api.close();
    },
  );
  test(
    'playback pause cancels active metadata and rejects queued work while playback detail remains available',
    () async {
      final client = AbortClient();
      final current = EmbyClient(client: client)..session = syntheticSession();
      final task = current.backgroundWork.run(() => current.browseItems());
      final cancelled = expectLater(task, throwsA(isA<BackgroundPaused>()));
      await client.started.future;
      final owner = Object();
      current.backgroundWork.pause(owner, true);
      await cancelled;
      expect(client.aborted, 1);
      expect(current.connection.status, ServerStatus.unknown);
      await expectLater(
        current.backgroundWork.run(() => current.libraries()),
        throwsA(isA<BackgroundPaused>()),
      );
      await current.detail('movie');
      expect(client.details, 1);
      current.backgroundWork.pause(owner, false);
      current.close();
    },
  );
  testWidgets(
    'a successful connection check refreshes a failed catalogue despite cooldown and retains its scroll',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      var calls = 0, fail = false;
      Completer<void>? hold;
      final api = EmbyClient(
        client: MockClient((req) async {
          if (req.url.path.endsWith('/Views')) {
            return response('{"Items":[]}', 200);
          }
          if (!req.url.path.endsWith('/Items')) {
            return response('{"Id":"user-1"}', 200);
          }
          calls++;
          if (fail) throw http.ClientException('offline');
          if (hold != null) await hold.future;
          return response(
            jsonEncode({
              'Items': [
                for (var i = 0; i < 100; i++)
                  {
                    'Id': '$i',
                    'Name': 'A ${i.toString().padLeft(3, "0")}',
                    'Type': 'Series',
                    'RecursiveItemCount': 24,
                  },
              ],
              'TotalRecordCount': 100,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      for (var i = 0; i < 10 && find.text('24 集').evaluate().isEmpty; i++) {
        await settleOffline(tester);
      }
      expect(
        find.text('24 集'),
        findsWidgets,
        reason:
            'calls=$calls; ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
      );
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(1700);
      await tester.pump();
      fail = true;
      final refresh = tester
          .widget<ReleaseRefreshScrollView>(
            find.byType(ReleaseRefreshScrollView, skipOffstage: false),
          )
          .onRefresh;
      final failing = refresh();
      await tester.pumpAndSettle();
      await failing;
      expect(find.textContaining('更新失败'), findsOneWidget);
      fail = false;
      hold = Completer<void>();
      await api.testConnection();
      await tester.pump();
      expect(calls, 3);
      expect(
        find.textContaining('更新失败'),
        findsOneWidget,
        reason: 'a connection alone is not successful catalogue refresh',
      );
      hold.complete();
      hold = null;
      await settleOffline(tester);
      expect(find.textContaining('更新失败'), findsNothing);
      expect(scroll.offset, 1700);
      await tester.tap(find.byKey(const Key('scroll-to-top')));
      await tester.pump();
      expect(scroll.offset, 1700, reason: 'scroll starts without a jump');
      await tester.pump(const Duration(milliseconds: 300));
      expect(scroll.offset, inExclusiveRange(0, 1700));
      expect(PosterDemand.loadingPaused.value, true);
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
      expect(find.byKey(const Key('scroll-to-top')), findsNothing);
      await tester.pump(const Duration(milliseconds: 125));
      expect(PosterDemand.loadingPaused.value, false);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
    },
  );
  testWidgets(
    'settings connection button coalesces presses and displays disconnection then success',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      var calls = 0, fail = true;
      Completer<void>? gate = Completer<void>();
      final api = EmbyClient(
        client: MockClient((req) async {
          calls++;
          expect(req.url.path, '/proxy/emby/Users/synthetic-user');
          if (gate != null) await gate.future;
          if (fail) throw http.ClientException('offline');
          return response('{"Id":"user-1"}', 200);
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsPage(store: store, browse: repo),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('test-emby-connection-arrow')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      for (var i = 0; i < 5; i++) {
        await tester.tapAt(
          tester.getCenter(find.byKey(const Key('test-emby-connection-arrow'))),
        );
      }
      await tester.pump();
      expect(calls, 1);
      expect(find.text('正在测试…'), findsOneWidget);
      gate.complete();
      gate = null;
      await tester.pumpAndSettle();
      expect(api.connection.status, ServerStatus.disconnected);
      expect(find.textContaining('网络连接失败'), findsOneWidget);
      fail = false;
      await tester.tap(find.byKey(const Key('test-emby-connection-arrow')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.textContaining('连接正常'), findsOneWidget);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    },
  );
}
