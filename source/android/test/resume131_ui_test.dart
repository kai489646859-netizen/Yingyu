// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'core_test.dart' show response, syntheticSession;
import 'watch_resume131_test.dart' show ep;
import 'offline_settle.dart';
import 'poster_cached_drag_test.dart' show CachedPosterFixture;
import 'package:yingyu/ui/poster.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    syntheticImagePaths();
    final path = Platform.environment['YINGYU_TEST_FONT'];
    if (path != null) {
      for (final name in [
        'Roboto',
        'Ahem',
        '.SF UI Text',
        '.SF UI Display',
        'CupertinoSystemText',
        'CupertinoSystemDisplay',
      ]) {
        await (FontLoader(name)..addFont(
              Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
            ))
            .load();
      }
    }
  });
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'real home caption and opened detail agree on episode and progress, $brightness',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        tester.view.physicalSize = const Size(1920, 1256);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final oldPoster = posterCache, oldArtwork = artworkCache;
        posterCache = CachedPosterFixture();
        artworkCache = CachedPosterFixture();
        addTearDown(() {
          posterCache = oldPoster;
          artworkCache = oldArtwork;
        });
        final store = AppStore(await SharedPreferences.getInstance());
        final selected = ep(8, date: '2026-10-22T00:03:00Z');

        final api = EmbyClient(
          client: MockClient((r) async {
            final path = r.url.path;
            if (path.endsWith('/Resume')) {
              return response(
                jsonEncode({
                  'Items': [selected.data],
                }),
                200,
              );
            }
            if (path.endsWith('/series')) {
              return response(
                '{"Id":"series","Type":"Series","Name":"合成剧集"}',
                200,
              );
            }
            if (path.endsWith('/Seasons')) {
              return response(
                '{"Items":[{"Id":"season","Name":"第 1 季","IndexNumber":1}]}',
                200,
              );
            }
            if (path.endsWith('/Episodes')) {
              return response(
                jsonEncode({
                  'Items': List.generate(14, (i) => ep(i + 1).data),
                  'TotalRecordCount': 14,
                }),
                200,
              );
            }
            if (path.endsWith('/Items')) {
              return response(
                jsonEncode({
                  'Items': [selected.data],
                }),
                200,
              );
            }
            fail('Unexpected metadata request');
          }),
        )..session = syntheticSession();
        final feed = HomeFeed(api, store);
        await feed.refreshResume(force: true);
        final capture = GlobalKey();
        var played = 0;
        String? playedId;
        Duration? playedPosition;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: appTheme(brightness),
              home: Scaffold(
                body: Builder(
                  builder: (context) => AnimatedBuilder(
                    animation: feed,
                    builder: (context, _) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 40),
                        const Text('首页', style: TextStyle(fontSize: 32)),
                        ContinueWatching(
                          feed: feed,
                          active: true,
                          onPlay: (item) async {
                            played++;
                            playedId = item.id;
                            playedPosition = item.resume;
                          },
                          onDetail: (entry) async {
                            await showSurface<void>(
                              context,
                              (_) => DetailPage(
                                item: MediaItem({
                                  'Id': 'series',
                                  'Type': 'Series',
                                  'Name': '合成剧集',
                                }),
                                api: api,
                                store: store,
                                resumeEpisode:
                                    feed.recentEpisode('series') ?? entry,
                                watchedEpisode: feed.lastWatchedEpisode,
                                play: (_, _, _) async {
                                  played++;
                                },
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('resume-e8')), findsOneWidget);
        expect(find.byKey(const ValueKey('resume-e9')), findsNothing);
        final beforeDetails = tester.widget<LinearProgressIndicator>(
          find.byKey(const ValueKey('resume-progress-e8')),
        );
        expect(beforeDetails.value, closeTo(2388 / 3318, 1e-9));
        expect(played, 0);
        await tester.tap(find.byKey(const ValueKey('resume-play-e8')));
        await tester.pumpAndSettle();
        expect(played, 1);
        expect(playedId, 'e8');
        expect(playedPosition, const Duration(seconds: 2388));
        played = 0;
        await tester.tap(find.byKey(const ValueKey('resume-e8')));
        await tester.pumpAndSettle();
        expect(find.text('上次观看：第 1 季 · 第 8 集'), findsOneWidget);
        expect(find.byKey(const ValueKey('resume-e8')), findsOneWidget);
        expect(find.byKey(const ValueKey('resume-e9')), findsNothing);
        final current = tester.widget<CupertinoButton>(
          find.byKey(const ValueKey('detail-episode-e8')),
        );
        expect(current.color, isNotNull);
        final indicator = tester.widget<LinearProgressIndicator>(
          find.byKey(const ValueKey('resume-progress-e8')),
        );
        expect(indicator.value, closeTo(2388 / 3318, 1e-9));
        expect(played, 0);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/watch131/previews/home-detail-${brightness.name}.png',
          )..parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        feed.dispose();
        api.close();
        store.dispose();
      },
    );
  }
}
