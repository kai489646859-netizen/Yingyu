import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/server_connection.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/subtitle_search.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'host/subtitle163/old_emby.dart' as old;
import 'manual_subtitles100_test.dart' show ManualBackend;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

const oldClient = bool.fromEnvironment('YINGYU_SUBTITLE163_OLD');

// MockClient buffers into Request and loses AbortableRequest's cancellation.
// Preserve the actual request type at this transport seam.
class StreamingClient extends http.BaseClient {
  StreamingClient(this.handler);
  final Future<http.Response> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

dynamic client(http.Client transport, {DiagnosticLog? log}) {
  final dynamic value = oldClient
      ? old.EmbyClient(client: transport, log: log)
      : EmbyClient(client: transport, log: log);
  value.session = syntheticSession();
  return value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syntheticImagePaths();
  });
  test(
    'provider returning at 25s is not discarded by metadata 18s deadline',
    () {
      fakeAsync((time) {
        Object? failure;
        List<Json>? result;
        final api = client(
          MockClient((request) async {
            await Future<void>.delayed(const Duration(seconds: 25));
            return response('[{"Id":"chosen","Format":"srt"}]', 200);
          }),
        );
        (api.searchSubtitles('movie', 'chi', 'source') as Future<List<Json>>)
            .then<void>(
              (v) {
                result = v;
              },
              onError: (Object e) {
                failure = e;
              },
            );
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 19));
        expect(failure, isNull);
        expect(result, isNull);
        time.elapse(const Duration(seconds: 6));
        expect(result?.single['Id'], 'chosen');
        expect(failure, isNull);
        api.close();
      });
    },
  );
  test(
    'subtitle timeout is bounded, aborts request and preserves working account',
    () {
      fakeAsync((time) {
        var aborted = false;
        Object? failure;
        final gate = Completer<http.Response>();
        final api = client(
          StreamingClient((request) {
            if (request is http.AbortableRequest) {
              request.abortTrigger?.then((_) => aborted = true);
            }
            return gate.future;
          }),
        );
        api.connection.finish(api.connection.begin(), ServerStatus.connected);
        (api.searchSubtitles('movie', 'chi', 'source') as Future<List<Json>>)
            .then<void>(
              (_) {},
              onError: (Object e) {
                failure = e;
              },
            );
        time.flushMicrotasks();
        time.elapse(const Duration(seconds: 89));
        expect(failure, isNull);
        time.elapse(const Duration(seconds: 1));
        expect(failure, isA<AppFailure>());
        expect('$failure', contains('字幕搜索超时'));
        expect('$failure', isNot(contains('播放地址')));
        expect(aborted, true);
        expect(api.connection.status, ServerStatus.connected);
        gate.complete(response('[]', 200));
        time.flushMicrotasks();
        api.close();
      });
    },
  );
  for (final status in [403, 429, 500]) {
    test('subtitle HTTP $status stays local to the search operation', () async {
      final api = client(MockClient((r) async => response('{}', status)));
      api.connection.finish(api.connection.begin(), ServerStatus.connected);
      await expectLater(
        api.searchSubtitles('movie', 'chi', 'source'),
        throwsA(isA<AppFailure>()),
      );
      expect(api.connection.status, ServerStatus.connected);
      api.close();
    });
  }
  test(
    'empty response is logged as zero results with fixed operation and no IDs',
    () async {
      final log = DiagnosticLog(console: false);
      final api = client(
        MockClient((r) async => response('[]', 200)),
        log: log,
      );
      expect(
        await api.searchSubtitles('PRIVATE_ITEM', 'chi', 'PRIVATE_SOURCE'),
        isEmpty,
      );
      final text = log.entries.map((e) => e.message).join('\n');
      expect(text, contains('在线字幕搜索'));
      expect(text, contains('结果=0'));
      expect(text, isNot(contains('PRIVATE_ITEM')));
      expect(text, isNot(contains('PRIVATE_SOURCE')));
      api.close();
      log.dispose();
    },
  );
  test('ordinary metadata keeps its original 18s deadline', () {
    fakeAsync((time) {
      Object? failure;
      final gate = Completer<http.Response>();
      final api = client(MockClient((r) => gate.future));
      (api.api('Users/test') as Future<Json>).then<void>(
        (_) {},
        onError: (Object e) {
          failure = e;
        },
      );
      time.flushMicrotasks();
      time.elapse(const Duration(seconds: 18));
      expect(failure, isA<AppFailure>());
      gate.complete(response('{}', 200));
      time.flushMicrotasks();
      api.close();
    });
  });

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    for (final empty in [false, true]) {
      testWidgets(
        'search wait/cancel and empty result ${size.width} empty=$empty',
        (tester) async {
          setDisplay(tester, size);
          final gate = Completer<http.Response>();
          var aborted = false, calls = 0;
          final store = AppStore(await SharedPreferences.getInstance());
          final api = EmbyClient(
            client: StreamingClient((request) {
              calls++;
              if (request is http.AbortableRequest) {
                request.abortTrigger?.then((_) => aborted = true);
              }
              return empty ? Future.value(response('[]', 200)) : gate.future;
            }),
          )..session = syntheticSession();
          final backend = ManualBackend();
          final session =
              PlaybackSession(
                  api: api,
                  store: store,
                  item: MediaItem({'Id': 'movie'}),
                  backend: backend,
                )
                ..route = PlaybackRoute(
                  url: 'http://127.0.0.1:9/synthetic',
                  sourceId: 'source',
                  sessionId: '',
                  headers: const {},
                  streams: const [],
                );
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(Brightness.dark),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(body: SubtitleSearch(session: session)),
              ),
            ),
          );
          expect(calls, 0);
          await tester.tap(find.byKey(const Key('online-subtitle-search')));
          await tester.pump();
          if (empty) {
            expect(find.text('没有找到字幕'), findsOneWidget);
            expect(find.textContaining('服务器返回了空结果'), findsOneWidget);
          } else {
            await tester.pump(const Duration(seconds: 20));
            expect(find.textContaining('字幕搜索失败'), findsNothing);
            expect(find.textContaining('正在等待 Emby 字幕源'), findsOneWidget);
            await captureOffline(
              tester,
              boundary,
              'subtitle163-wait-${size.width.toInt()}',
            );
            await tester.tap(find.byKey(const Key('online-subtitle-cancel')));
            await tester.pump();
            expect(aborted, true);
            gate.complete(
              response('[{"Id":"late","Name":"stale","Format":"srt"}]', 200),
            );
            await tester.pump();
            expect(find.text('stale'), findsNothing);
            expect(find.text('重新搜索'), findsOneWidget);
          }
          await captureOffline(
            tester,
            boundary,
            'subtitle163-${empty ? 'empty' : 'cancel'}-${size.width.toInt()}',
          );
          expect(calls, 1);
          expect(backend.plays, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          api.close();
          await backend.dispose();
          store.log.dispose();
          store.dispose();
        },
      );
    }
  }
}
