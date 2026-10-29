// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/pipeline_metrics.dart';
import 'core_test.dart' show response, syntheticSession, playbackData;
import 'watch_resume131_test.dart' show ep;
import 'track_menu_test.dart' show MenuBackend;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;

class _Notice149 extends MenuBackend implements MediaNoticeBackend {
  @override
  String get sourceNotice => 'SDR · 标准动态范围';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'presentation observations accept only consistent bounded numeric rows',
    () {
      const row =
          'Yingyu present149 window_us=2000000 frames=100 admitted=80 dropped=20 queue_late=15 vo_late=5 gap_max_us=60000 age_max_us=15000 late_max_us=5000';
      expect(pipelineStageMessage('vo/gpu', row), contains('排队时已晚=15；进入后过期=5'));
      expect(pipelineStageMessage('vo/gpu', row), contains('非单一解码耗时'));
      for (final bad in [
        row.replaceFirst('frames=100', 'frames=101'),
        row.replaceFirst('queue_late=15', 'queue_late=16'),
        row.replaceFirst('window_us=2000000', 'window_us=1999999'),
        '$row https://secret.invalid',
        row.replaceFirst('age_max_us=15000', 'age_max_us=5000001'),
      ]) {
        expect(pipelineStageMessage('vo/gpu', bad), isNull);
      }
      expect(pipelineStageMessage('ffmpeg/video', row), isNull);
    },
  );
  for (final equalDate in [false, true]) {
    test(
      'detail history16 and server Resume14 keep their independent checkpoints, equalDate=$equalDate',
      () async {
        final store = AppStore(await SharedPreferences.getInstance());
        final older = ep(
          14,
          seconds: 500,
          date: equalDate ? '2026-10-25T00:02:00Z' : '2026-10-25T00:00:00Z',
        );
        final history = ep(16, seconds: 22, date: '2026-10-25T00:02:00Z');
        final api = EmbyClient(
          client: MockClient(
            (r) async => response(
              jsonEncode({
                'Items': [
                  r.url.path.endsWith('/Resume') ? older.data : history.data,
                ],
              }),
              200,
            ),
          ),
        )..session = syntheticSession();
        var feed = HomeFeed(api, store);
        await store.prefs.setString(
          feed.cacheKey,
          jsonEncode({
            'items': [
              {'item': older.data, 'observedAt': '2026-10-25T00:00:00Z'},
            ],
          }),
        );
        feed.dispose();
        await store.saveProgress(
          api.session!,
          older.id,
          const Duration(seconds: 501),
          serverBaseline: older,
        );
        feed = HomeFeed(api, store);
        try {
          await feed.refreshResume(force: true);
          expect((await feed.lastWatchedEpisode('series'))!.id, 'e16');
          expect(
            feed.resume.single.id,
            'e14',
            reason:
                'The home follows Resume14 while detail history resolves16; neither may erase pending501.',
          );
          expect(feed.resume.single.resume, const Duration(seconds: 500));
          expect(
            store.localProgress(api.session!, 'e14'),
            const Duration(seconds: 501),
            reason:
                'A metadata-only correction must not erase an unsynced checkpoint.',
          );
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'e14');
        } finally {
          feed.dispose();
          api.close();
          store.dispose();
        }
      },
    );
  }
  test(
    'a local rewatch14 preserves its pending value while server displays16',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      final older = ep(
        14,
        seconds: 500,
        date: DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 30))
            .toIso8601String(),
      );
      final history = ep(
        16,
        seconds: 22,
        date: DateTime.now()
            .toUtc()
            .subtract(const Duration(minutes: 10))
            .toIso8601String(),
      );
      final methods = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          methods.add(r.method);
          return response(
            jsonEncode({
              'Items': [history.data],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      var feed = HomeFeed(api, store);
      await store.prefs.setString(
        feed.cacheKey,
        jsonEncode({
          'items': [
            {
              'item': older.data,
              'observedAt': DateTime.now().toIso8601String(),
            },
          ],
        }),
      );
      feed.dispose();
      await store.saveProgress(
        api.session!,
        older.id,
        const Duration(seconds: 540),
        serverBaseline: older,
      );
      feed = HomeFeed(api, store);
      try {
        await feed.refreshResume(force: true);
        expect((await feed.lastWatchedEpisode('series'))!.id, 'e16');
        expect(feed.resume.single.id, 'e16');
        expect(feed.resume.single.resume, const Duration(seconds: 22));
        expect(
          store.localProgress(api.session!, 'e14'),
          const Duration(seconds: 540),
        );
        expect(methods, everyElement('GET'));
      } finally {
        feed.dispose();
        api.close();
        store.dispose();
      }
    },
  );
  for (final phone in [true, false]) {
    testWidgets('real player notice is higher only on phone=$phone', (
      tester,
    ) async {
      setDisplay(
        tester,
        phone ? const Size(1056, 480) : const Size(1280, 800),
        dpr: phone ? 3 : 1,
      );
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final api = EmbyClient(
        client: MockClient(
          (r) async => r.url.path.endsWith('PlaybackInfo')
              ? response(jsonEncode(playbackData()), 200)
              : r.url.path.contains('Sessions/Playing')
              ? response('', 204)
              : response('{"Id":"movie","Type":"Movie"}', 200),
        ),
      )..session = syntheticSession();
      final backend = _Notice149()..gate.complete();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        Device.channel,
        (call) async => call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null,
      );
      final capture = GlobalKey();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: capture,
              child: PlayerPage(
                createSession: () => PlaybackSession(
                  api: api,
                  store: store,
                  item: MediaItem({'Id': 'movie'}),
                  backend: backend,
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final banner = find.text('SDR · 标准动态范围');
        expect(banner, findsOneWidget);
        final positioned = find
            .ancestor(of: banner, matching: find.byType(Positioned))
            .first;
        expect(tester.widget<Positioned>(positioned).top, phone ? 40 : 76);
        expect(tester.getTopLeft(banner).dy, lessThan(phone ? 100 : 140));
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/playback149/previews/notice-${phone ? 'phone' : 'tablet'}.png',
          )..parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.runAsync(backend.dispose);
        api.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
        messenger.setMockMethodCallHandler(Device.channel, null);
      }
    });
  }
}
