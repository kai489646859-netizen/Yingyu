import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/subtitle_document.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/subtitle_files.dart';
import 'package:yingyu/playback/subtitle_search.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'manual_subtitles100_test.dart' show ManualBackend;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

class LocalSubtitleHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syntheticImagePaths();
  });
  test(
    'search and provider route preserve account and provider identity without server writes',
    () async {
      final calls = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          calls.add(r.method);
          expect(
            r.url.path,
            '/proxy/emby/Items/movie/RemoteSearch/Subtitles/chi',
          );
          expect(r.url.queryParameters['MediaSourceId'], 'selected-source');
          return response(
            '[{"Id":"provider:sub/1","Format":"ass","Name":"合成字幕"}]',
            200,
          );
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      final results = await api.searchSubtitles(
        'movie',
        'chi',
        'selected-source',
      );
      final route = api.remoteSubtitleRoute('${results.single['Id']}');
      expect(
        route.url,
        endsWith('/Providers/Subtitles/Subtitles/provider%3Asub%2F1'),
      );
      expect(route.sameOriginHeaders['X-Emby-Token'], 'SYNTHETIC_TOKEN');
      expect(route.headers, isEmpty);
      expect(calls, ['GET']);
      expect(onlineSubtitleCodec(results.single), 'ass');
      expect(onlineSubtitleCodec({'Format': 'zip'}), isNull);
      expect(onlineSubtitleCodec({}), isNull);
    },
  );
  for (final codec in ['srt', 'ass', 'ssa', 'vtt']) {
    test(
      'selected $codec stream attaches without reopening video; cleaned on exit',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final requests = <String>[];
          server.listen((r) async {
            requests.add('${r.method} ${r.uri.path}');
            expect(r.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
            r.response.write(
              codec == 'vtt'
                  ? 'WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nSynthetic'
                  : 'Synthetic $codec subtitle',
            );
            await r.response.close();
          });
          final store = AppStore(await SharedPreferences.getInstance());
          final api =
              EmbyClient(
                  client: MockClient(
                    (r) async => r.url.path.endsWith('PlaybackInfo')
                        ? response(jsonEncode(playbackData()), 200)
                        : r.url.path.contains('Sessions/Playing')
                        ? response('', 204)
                        : response('{"Id":"movie","Type":"Movie"}', 200),
                  ),
                )
                ..session = syntheticSession(
                  'http://127.0.0.1:${server.port}/proxy/emby',
                );
          final backend = ManualBackend()..gate.complete();
          final session = PlaybackSession(
            api: api,
            store: store,
            item: MediaItem({'Id': 'movie'}),
            backend: backend,
          );
          final files = SubtitleFiles(maxBytes: 8 * 1024 * 1024);
          addTearDown(() async {
            await session.close();
            await files.close();
            api.close();
            store.log.dispose();
            store.dispose();
          });
          await session.open();
          final video = backend.receivedRoute, plays = backend.plays;
          final file = await files.load(
            'selected',
            api.remoteSubtitleRoute('provider-result'),
            codec,
          );
          expect(file.path, endsWith('.$codec'));
          await session.attachSubtitle(
            SubtitleDocument(
              file.path,
              'Online',
              codec,
              files.close,
              language: 'chi',
            ),
          );
          expect(session.selectedTrack(true), 'manual-1');
          expect(backend.receivedRoute, same(video));
          expect(backend.plays, plays);
          expect(requests, [
            'GET /proxy/emby/Providers/Subtitles/Subtitles/provider-result',
          ]);
          expect(await file.exists(), true);
          await session.close();
          expect(await file.exists(), false);
        }, LocalSubtitleHttp());
      },
    );
  }
  for (final status in [200, 403]) {
    testWidgets(
      'online panel exposes results or a retryable permission error $status',
      (tester) async {
        setDisplay(tester, const Size(390, 844));
        final store = AppStore(await SharedPreferences.getInstance());
        final calls = <String>[];
        final api = EmbyClient(
          client: MockClient((r) async {
            calls.add(r.method);
            return response(
              status == 200
                  ? jsonEncode([
                      {
                        'Id': 'text',
                        'Name': '合成中文字幕',
                        'ProviderName': 'Synthetic',
                        'Format': 'ass',
                        'ThreeLetterISOLanguageName': 'chi',
                        'IsHashMatch': true,
                      },
                      {'Id': 'archive', 'Name': '压缩包', 'Format': 'zip'},
                    ])
                  : '{"Message":"synthetic permission"}',
              status,
            );
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
        addTearDown(() {
          api.close();
          store.log.dispose();
          store.dispose();
        });
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
        expect(calls, isEmpty);
        await tester.tap(find.byKey(const Key('online-subtitle-search')));
        await settleOffline(tester);
        expect(calls, ['GET']);
        if (status == 200) {
          expect(find.text('合成中文字幕'), findsOneWidget);
          expect(find.textContaining('文件匹配'), findsOneWidget);
          expect(find.textContaining('暂不支持此格式'), findsOneWidget);
        } else {
          expect(find.textContaining('字幕搜索失败'), findsOneWidget);
          expect(find.text('重新搜索'), findsOneWidget);
        }
        await captureOffline(tester, boundary, 'online157-$status');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await backend.dispose();
      },
    );
  }
  testWidgets(
    'closing a search rejects a late response without a subtitle download',
    (tester) async {
      final gate = Completer<String>();
      final store = AppStore(await SharedPreferences.getInstance());
      var requests = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          requests++;
          return response(await gate.future, 200);
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
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(body: SubtitleSearch(session: session)),
        ),
      );
      await tester.tap(find.byKey(const Key('online-subtitle-search')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      gate.complete('[{"Id":"late","Name":"Late","Format":"srt"}]');
      await tester.pump(const Duration(seconds: 1));
      expect(requests, 1);
      expect(backend.plays, 0);
      expect(tester.takeException(), isNull);
      api.close();
      store.log.dispose();
      store.dispose();
      await backend.dispose();
    },
  );
}
