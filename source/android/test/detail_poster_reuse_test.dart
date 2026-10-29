import 'dart:convert';
import 'dart:io' as io;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/image_cache_budget.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/poster_art.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, syntheticSession;
import 'image_budget_test.dart' show TestFiles;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    final fallback = io.Directory('build/synthetic-art/reuse-cache')
      ..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => fallback.absolute.path,
        );
  });
  for (final type in ['Movie', 'Series', 'Episode']) {
    for (final backdrop in [false, true]) {
      testWidgets(
        '$type detail reuses wall poster from disk; backdrop=$backdrop',
        (tester) async {
          await tester.runAsync(() async {
            tester.view.physicalSize = const Size(1280, 800);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            VisibilityDetectorController.instance.updateInterval =
                Duration.zero;
            PaintingBinding.instance.imageCache.clear();
            PaintingBinding.instance.imageCache.clearLiveImages();
            final requests = <String>[];
            final api = EmbyClient(
              client: MockClient((r) async {
                if (r.url.queryParameters['SortBy'] == 'DatePlayed') {
                  return response('{"Items":[]}', 200);
                }
                if (r.url.path.endsWith('/Seasons')) {
                  return response('{"Items":[]}', 200);
                }
                expect(r.url.path, endsWith('/item'));
                return response(
                  jsonEncode({
                    'Id': 'item',
                    'Type': type,
                    'Name': '合成详情',
                    'ImageTags': {'Primary': 'poster-tag'},
                    if (type == 'Episode') ...{
                      'SeriesId': 'series',
                      'SeriesPrimaryImageTag': 'series-tag',
                    },
                    if (backdrop) 'BackdropImageTags': ['background-tag'],
                  }),
                  200,
                );
              }),
            )..session = syntheticSession();
            final item = MediaItem({
              'Id': 'item',
              'Type': type,
              'Name': '合成详情',
              'ImageTags': {'Primary': 'poster-tag'},
              if (type == 'Episode') ...{
                'SeriesId': 'series',
                'SeriesPrimaryImageTag': 'series-tag',
              },
              if (backdrop) 'BackdropImageTags': ['background-tag'],
            });
            final oldPosters = posterCache, oldArtwork = artworkCache;
            late io.Directory root;
            late ImageCacheBudget budget;
            await (() async {
              root = await io.Directory.systemTemp.createTemp(
                'yingyu-detail-reuse-',
              );
              final recorder = ui.PictureRecorder();
              Canvas(recorder).drawRect(
                const Rect.fromLTWH(0, 0, 24, 36),
                Paint()..color = Colors.blue,
              );
              final picture = recorder.endRecording();
              final image = await picture.toImage(24, 36);
              final data = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!.buffer.asUint8List();
              image.dispose();
              picture.dispose();
              final downloads = PosterFileService(
                spacing: Duration.zero,
                visible: (_) => true,
                client: MockClient((r) async {
                  requests.add(r.url.path);
                  return http.Response.bytes(
                    data,
                    200,
                    headers: {
                      'content-type': 'image/png',
                      'cache-control': 'max-age=31536000',
                    },
                  );
                }),
              );
              budget = ImageCacheBudget(limitBytes: 1024 * 1024);
              BudgetCacheManager cache(String name, bool artwork) =>
                  BudgetCacheManager(
                    Config(
                      name,
                      fileService: downloads,
                      fileSystem: TestFiles('${root.path}/$name'),
                      repo: JsonCacheInfoRepository.withFile(
                        io.File('${root.path}/$name.json'),
                      ),
                    ),
                    budget,
                    isArtwork: artwork,
                  );
              posterCache = cache('poster', false);
              artworkCache = cache('artwork', true);
              await budget.initialize();
            })();
            Future<void> settle() async {
              await tester.pumpAndSettle();
              for (var i = 0; i < 12; i++) {
                await Future<void>.delayed(const Duration(milliseconds: 60));
                await tester.pumpAndSettle();
              }
            }

            addTearDown(() async {
              api.close();
              await posterCache.dispose();
              await artworkCache.dispose();
              posterCache = oldPosters;
              artworkCache = oldArtwork;
              budget.dispose();
              expect(
                root.absolute.path.startsWith(
                  io.Directory.systemTemp.absolute.path,
                ),
                true,
              );
              expect(
                root.path
                    .split(io.Platform.pathSeparator)
                    .last
                    .startsWith('yingyu-detail-reuse-'),
                true,
              );
              await root.delete(recursive: true);
            });
            await tester.pumpWidget(
              MaterialApp(
                home: Center(
                  child: SizedBox(
                    width: 120,
                    height: 180,
                    child: Poster(url: posterUrl(api, item)),
                  ),
                ),
              ),
            );
            await settle();
            expect(requests.length, 1);
            expect(find.byType(RawImage), findsOneWidget);
            final wallUrl = posterUrl(api, item)!;
            for (final coldMemory in [false, true]) {
              await tester.pumpWidget(const SizedBox());
              if (coldMemory) {
                PaintingBinding.instance.imageCache.clear();
                PaintingBinding.instance.imageCache.clearLiveImages();
              }
              await tester.pumpWidget(
                MaterialApp(
                  theme: appTheme(Brightness.light),
                  home: DetailPage(
                    item: item,
                    api: api,
                    play: (_, _, _) async => fail('Must not play'),
                  ),
                ),
              );
              await settle();
              final poster = tester.widget<Poster>(
                find.descendant(
                  of: find.byKey(const Key('detail-poster')),
                  matching: find.byType(Poster),
                ),
              );
              expect(requests.where((p) => p.endsWith('/Primary')).length, 1);
              expect(
                requests.where((p) => p.endsWith('/Backdrop/0')).length,
                backdrop ? 1 : 0,
              );
              expect(requests.length, backdrop ? 2 : 1);
              expect(poster.url, wallUrl);
              expect(poster.kind, PosterKind.poster);
              expect(tester.takeException(), null);
            }
            expect(item.id, 'item');
            await tester.pumpWidget(const SizedBox());
          });
        },
      );
    }
  }
}
