import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/image_cache_budget.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/poster_service.dart';
// CacheManager's public FileInfo uses package:file.
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
// ignore: depend_on_referenced_packages
import 'package:file/file.dart' as fs;
import 'poster_cached_drag_test.dart' show CachedPosterFixture;
import 'offline_settle.dart' show syntheticImagePaths;

class ReliabilityFiles implements FileSystem {
  ReliabilityFiles(this.path);
  final String path;
  @override
  Future<fs.File> createFile(String name) async {
    final dir = const LocalFileSystem().directory(path);
    await dir.create(recursive: true);
    return dir.childFile(name);
  }
}

class PendingLocalCache extends CachedPosterFixture {
  final lookup = Completer<FileInfo?>();
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) {
    local.add(key);
    return lookup.future;
  }
}

Future<void> imageFrames(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final paused in [false, true]) {
    testWidgets(
      'cached pixels are decoded before entering viewport, paused=$paused',
      (tester) async {
        syntheticImagePaths();
        tester.view.physicalSize = const Size(400, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        final original = posterCache,
            cache = CachedPosterFixture(),
            owner = Object();
        posterCache = cache;
        PosterDemand.pause(owner, paused);
        addTearDown(() {
          posterCache = original;
          PosterDemand.pause(owner, false);
        });
        const url = 'https://fixture.invalid/prepared-poster';
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 12, 18),
            Paint()..color = Colors.green,
          );
          final picture = recorder.endRecording(),
              image = await picture.toImage(12, 18);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/synthetic-ui-metadata/prepared-$paused.png');
          await file.writeAsBytes(data!.buffer.asUint8List());
          cache.files[url] = FileInfo(
            const LocalFileSystem().file(file.path),
            FileSource.Cache,
            DateTime(2000),
            url,
          );
          image.dispose();
          picture.dispose();
        });
        final scroll = ScrollController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                controller: scroll,
                scrollCacheExtent: const ScrollCacheExtent.pixels(400),
                children: const [
                  SizedBox(height: 650),
                  SizedBox(height: 180, child: Poster(url: url)),
                ],
              ),
            ),
          ),
        );
        await imageFrames(tester);
        expect(PosterDemand.visible(url), false);
        expect(cache.local, [url]);
        expect(cache.network, isEmpty);
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage, skipOffstage: false))
              .any((i) => i.image != null),
          true,
        );
        scroll.jumpTo(230);
        await tester.pump();
        await tester.pump();
        expect(
          tester
              .widgetList<RawImage>(find.byType(RawImage, skipOffstage: false))
              .any((i) => i.image != null),
          true,
        );
        expect(cache.network, isEmpty);
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
      },
    );
  }
  testWidgets(
    'a visible poster waits for local lookup before requesting network',
    (tester) async {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final original = posterCache, cache = PendingLocalCache();
      posterCache = cache;
      addTearDown(() => posterCache = original);
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            height: 180,
            child: Poster(url: 'https://fixture.invalid/pending'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final early = List.of(cache.network);
      cache.lookup.complete(null);
      await tester.pumpAndSettle();
      expect(early, isEmpty);
      expect(cache.network, isNotEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  group('cache retention and duplicate download checks', () {
    late Directory root;
    late ImageCacheBudget budget;
    late BudgetCacheManager wall, art;
    var requests = 0;
    BudgetCacheManager manager(String name) => BudgetCacheManager(
      Config(
        name,
        fileSystem: ReliabilityFiles('${root.path}/$name'),
        repo: JsonCacheInfoRepository.withFile(File('${root.path}/$name.json')),
        stalePeriod: const Duration(days: 36500),
        maxNrOfCacheObjects: 100000,
        fileService: HttpFileService(
          httpClient: MockClient((_) async {
            requests++;
            await Future<void>.delayed(const Duration(milliseconds: 5));
            return http.Response.bytes(
              Uint8List(60),
              200,
              headers: {
                'cache-control': 'no-cache',
                'content-type': 'image/png',
              },
            );
          }),
        ),
      ),
      budget,
      isArtwork: name == 'art',
    );
    setUp(() async {
      root = await Directory.systemTemp.createTemp('yingyu-retention-test-');
      budget = ImageCacheBudget(limitBytes: 300);
      wall = manager('wall');
      art = manager('art');
      requests = 0;
    });
    tearDown(() async {
      await wall.dispose();
      await art.dispose();
      budget.dispose();
      expect(
        root.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        true,
      );
      expect(
        root.uri.pathSegments
            .where((p) => p.isNotEmpty)
            .last
            .startsWith('yingyu-retention-test-'),
        true,
      );
      await root.delete(recursive: true);
    });
    test('default retains both categories past 60 days and restart', () async {
      for (final cache in [wall, art]) {
        final file = await cache.putFile(
          'https://fixture.invalid/old',
          Uint8List(60),
          key: 'old',
        );
        await file.setLastModified(
          DateTime.now().subtract(const Duration(days: 90)),
        );
      }
      await budget.initialize();
      expect(await art.getFileFromCache('old'), isNotNull);
      expect(await wall.getFileFromCache('old'), isNotNull);
      await wall.dispose();
      await art.dispose();
      budget.dispose();
      budget = ImageCacheBudget(limitBytes: 300);
      wall = manager('wall');
      art = manager('art');
      await budget.initialize();
      expect(await art.getFileFromCache('old'), isNotNull);
      expect(await wall.getFileFromCache('old'), isNotNull);
      expect(requests, 0);
    });
    test(
      'HTTP-expired exact image is reused after process restart without a second download',
      () async {
        const url = 'https://fixture.invalid/no-tag-poster';
        final first = (await wall.getFileStream(url).toList())
            .whereType<FileInfo>()
            .single;
        await wall.dispose();
        wall = manager('wall');
        final next = (await wall.getFileStream(url).toList())
            .whereType<FileInfo>()
            .toList();
        expect(requests, 1);
        expect(next.single.file.path, first.file.path);
        expect((await wall.config.repo.getAllObjects()).length, 1);
      },
    );
    test('simultaneous same-identity requests write only one file', () async {
      const key = 'yingyu-image:tmdb:v1:movie:550:poster:360:85';
      final batches = await Future.wait(
        List.generate(
          12,
          (i) => wall
              .getFileStream('https://fixture-$i.invalid/poster', key: key)
              .toList(),
        ),
      );
      expect(requests, 1);
      expect(
        batches
            .map((b) => b.whereType<FileInfo>().last.file.path)
            .toSet()
            .length,
        1,
      );
      expect((await wall.config.repo.getAllObjects()).length, 1);
      expect(budget.usedBytes, 60);
    });
    test('new artwork cannot displace an existing wall poster', () async {
      final poster = await wall.putFile(
        'https://fixture.invalid/wall',
        Uint8List(60),
        key: 'wall',
      );
      await budget.record(wall, (await wall.getFileFromCache('wall'))!, 'wall');
      await budget.setLimit(90);
      final large = await art.putFile(
        'https://fixture.invalid/art',
        Uint8List(60),
        key: 'art',
      );
      await budget.record(art, (await art.getFileFromCache('art'))!, 'art');
      expect(await poster.exists(), true);
      // A file being delivered may be protected briefly, but at the next sweep
      // it must yield to wall posters, including when it is newer than them.
      await budget.setLimit(90);
      expect(await poster.exists(), true);
      expect(await large.exists(), false);
      expect(budget.usedBytes, 60);
    });
  });
}
