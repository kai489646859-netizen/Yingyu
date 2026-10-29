import 'dart:io' as io;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/image_identity.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/image_cache_budget.dart';
import 'package:yingyu/ui/poster_art.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession;
import 'image_budget_test.dart' show TestFiles;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

class _PausedCache extends Fake implements CacheManager {
  _PausedCache(this.info);
  final FileInfo info;
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => info;
}

Future<io.File> _artwork() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 640, 360),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(640, 360), [
        const Color(0xFF204959),
        const Color(0xFF8ABAC4),
      ]),
  );
  canvas.drawCircle(
    const Offset(510, 84),
    42,
    Paint()..color = const Color(0xFFFFD9A0),
  );
  canvas.drawPath(
    Path()
      ..moveTo(0, 290)
      ..lineTo(180, 120)
      ..lineTo(350, 290)
      ..lineTo(480, 170)
      ..lineTo(640, 290)
      ..lineTo(640, 360)
      ..lineTo(0, 360)
      ..close(),
    Paint()..color = const Color(0xFF285163),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(640, 360);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = io.File('build/synthetic-landscape156/artwork.png').absolute;
  await file.parent.create(recursive: true);
  await file.writeAsBytes(data!.buffer.asUint8List());
  picture.dispose();
  image.dispose();
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  test(
    'series landscape reuses its verified work identity without borrowing episode IDs',
    () {
      SharedImageIdentity.reset();
      final api = EmbyClient()..session = syntheticSession();
      final series = MediaItem({
        'Id': 's',
        'Type': 'Series',
        'ProviderIds': {'Tmdb': '10'},
        'ImageTags': {'Primary': 'primary'},
        'BackdropImageTags': ['back'],
      });
      final original = SharedImageIdentity.key(
        api.imageUrl(series, backdrop: true),
        artwork: true,
      );
      final episode = MediaItem({
        'Id': 'e',
        'Type': 'Episode',
        'SeriesId': 's',
        'SeriesPrimaryImageTag': 'primary',
        'ParentBackdropItemId': 's',
        'ParentBackdropImageTags': ['back'],
        'ProviderIds': {'Tmdb': '999'},
      });
      expect(
        SharedImageIdentity.key(resumeArtworkUrl(api, episode)!, artwork: true),
        original,
      );
      expect(original, contains('tv:10:backdrop'));
      expect(episode.id, 'e');
      api.close();
    },
  );
  test(
    'landscape budget persists independently; shares the actual request scheduler',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = InterfacePreferences(prefs);
      expect(settings.landscapeCacheGB, 1);
      await settings.setLandscapeCacheGB(3);
      expect(InterfacePreferences(prefs).landscapeCacheGB, 3);
      expect(settings.actorCacheGB, 1);
      expect(settings.cacheGB, 5);
      final service = (landscapeCache as BudgetCacheManager).config.fileService;
      expect(
        identical(
          service,
          (posterCache as BudgetCacheManager).config.fileService,
        ),
        true,
      );
      expect(
        identical(
          service,
          (artworkCache as BudgetCacheManager).config.fileService,
        ),
        true,
      );
      setImageRequestLimit(1);
      expect((service as PosterFileService).requestLimit, 1);
      expect(
        (actorCache as BudgetCacheManager).config.fileService,
        same(service),
      );
      setImageRequestLimit(3);
      settings.dispose();
    },
  );
  test(
    'known parent thumbnail supplies horizontal art without probing missing backdrops',
    () {
      final api = EmbyClient()..session = syntheticSession();
      final item = MediaItem({
        'Id': 'e',
        'Type': 'Episode',
        'SeriesId': 's',
        'ParentThumbItemId': 's',
        'ParentThumbImageTag': 'thumb',
      });
      final uri = Uri.parse(resumeArtworkUrl(api, item)!);
      expect(uri.path, endsWith('/Items/s/Images/Thumb'));
      expect(uri.queryParameters['tag'], 'thumb');
      expect(uri.queryParameters['maxWidth'], '640');
      final thumbKey = SharedImageIdentity.key(
        api.imageUrl(
          MediaItem({
            'Id': 'm',
            'Type': 'Movie',
            'ProviderIds': {'Tmdb': '99'},
            'ImageTags': {'Primary': 'p', 'Thumb': 't'},
          }),
          thumbnail: true,
        ),
      );
      expect(thumbKey, contains('thumb:640'));
      api.close();
    },
  );
  test(
    'exact cached images reuse local bytes; clear and quotas stay independent',
    () async {
      final root = await io.Directory.systemTemp.createTemp(
        'yingyu-landscape156-',
      );
      final a = ImageCacheBudget(limitBytes: 200),
          b = ImageCacheBudget(limitBytes: 120);
      var requests = 0;
      Config config(String name) => Config(
        name,
        fileSystem: TestFiles('${root.path}/$name'),
        repo: JsonCacheInfoRepository.withFile(
          io.File('${root.path}/$name.json'),
        ),
        fileService: HttpFileService(
          httpClient: MockClient((_) async {
            requests++;
            return http.Response.bytes(Uint8List(80), 200);
          }),
        ),
        maxNrOfCacheObjects: 1000,
      );
      final source = BudgetCacheManager(config('source'), a);
      final wide = BudgetCacheManager(config('wide'), b, reuseFrom: [source]);
      try {
        const url =
            'https://fixture.invalid/Items/one/Images/Backdrop/0?tag=one';
        final key = SharedImageIdentity.key(url, artwork: true);
        await source.putFile(url, Uint8List(80), key: key);
        final info = (await source.getFileFromCache(key))!;
        await a.record(source, info, key);
        final copies = await Future.wait([
          wide.getFileStream(url, key: key).toList(),
          wide.getFileStream(url, key: key).toList(),
        ]);
        final first = copies.first.whereType<FileInfo>().single;
        expect(
          (await wide.directory()).listSync().whereType<io.File>().length,
          1,
        );
        expect(requests, 0);
        expect(first.file.path, isNot(info.file.path));
        expect(await first.file.readAsBytes(), await info.file.readAsBytes());
        expect(a.usedBytes, 80);
        expect(b.usedBytes, 80);
        await wide.getFileStream(url, key: key).toList();
        expect(b.usedBytes, 80);
        await wide.emptyCache();
        expect(await info.file.exists(), true);
        expect(a.usedBytes, 80);
        expect(b.usedBytes, 0);
        await wide.getFileStream(url, key: key).toList();
        await source.emptyCache();
        expect(b.usedBytes, 80);
        expect((await wide.getFileFromCache(key))!.file.existsSync(), true);
        await b.setLimit(50);
        expect(b.usedBytes, 0);
        expect(requests, 0);
      } finally {
        await wide.dispose();
        await source.dispose();
        a.dispose();
        b.dispose();
        expect(
          root.absolute.path.startsWith(io.Directory.systemTemp.absolute.path),
          true,
        );
        expect(
          root.path
              .split(io.Platform.pathSeparator)
              .last
              .startsWith('yingyu-landscape156-'),
          true,
        );
        await root.delete(recursive: true);
      }
    },
  );
  for (final size in [
    const Size(320, 740),
    const Size(412, 915),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'wide resume card keeps media identity and progress $size dark=$dark',
        (tester) async {
          setDisplay(tester, size);
          final pause = Object();
          PosterDemand.pause(pause, true);
          final oldCache = landscapeCache;
          final art = (await tester.runAsync(_artwork))!;
          final imageFile = (await tester.runAsync(
            () => TestFiles(art.parent.path).createFile('artwork.png'),
          ))!;
          landscapeCache = _PausedCache(
            FileInfo(
              imageFile,
              FileSource.Cache,
              DateTime.now().add(const Duration(days: 1)),
              'https://fixture.invalid/artwork',
            ),
          );
          addTearDown(() {
            landscapeCache = oldCache;
            PosterDemand.pause(pause, false);
          });
          final api = EmbyClient(
            client: MockClient(
              (_) async => throw StateError('No per-card metadata requests'),
            ),
          )..session = syntheticSession();
          final store = AppStore(await SharedPreferences.getInstance());
          final feed = HomeFeed(api, store);
          final item = MediaItem({
            'Id': 'episode26',
            'Type': 'Episode',
            'Name': '第26集',
            'SeriesName': '合成影视资源',
            'SeriesId': 'series',
            'ParentIndexNumber': 1,
            'IndexNumber': 26,
            'ParentBackdropItemId': 'series',
            'ParentBackdropImageTags': ['wide-tag'],
            'SeriesPrimaryImageTag': 'poster-tag',
            'RunTimeTicks': 4800000000,
            'UserData': {'PlaybackPositionTicks': 1200000000},
          });
          feed.resume = [
            item,
            for (var n = 1; n < 5; n++)
              MediaItem({
                ...item.data,
                'Id': 'episode${26 + n}',
                'SeriesName': '合成影视资源 ${n + 1}',
              }),
          ];
          var played = '';
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(dark ? Brightness.dark : Brightness.light),
              home: RepaintBoundary(
                key: key,
                child: Scaffold(
                  body: ContinueWatching(
                    feed: feed,
                    active: true,
                    onPlay: (i) async {
                      played = i.id;
                    },
                    onDetail: (_) async {},
                    onViewAll: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (
            var n = 0;
            n < 12 &&
                !(tester.state(find.byType(Poster).first) as dynamic)
                    .imageReady;
            n++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pumpAndSettle();
          }
          expect(
            (tester.state(find.byType(Poster).first) as dynamic).imageReady,
            true,
          );
          final rect = tester.getRect(
            find.byKey(const ValueKey('resume-artwork-episode26')),
          );
          expect(rect.width / rect.height, closeTo(16 / 9, .001));
          expect(rect.width, lessThan(size.width));
          final image = tester.widget<Poster>(find.byType(Poster).first);
          expect(image.kind, PosterKind.landscape);
          expect(
            Uri.parse(image.url!).path,
            endsWith('/Items/series/Images/Backdrop/0'),
          );
          final bar = tester.widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('resume-progress-episode26')),
          );
          expect(bar.value, .25);
          await captureOffline(
            tester,
            key,
            'landscape156-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
          );
          await tester.tap(find.byKey(const ValueKey('resume-play-episode26')));
          await tester.pump();
          expect(played, 'episode26');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          PosterDemand.pause(pause, false);
          feed.dispose();
          api.close();
          store.log.dispose();
          store.dispose();
        },
      );
    }
  }
}
