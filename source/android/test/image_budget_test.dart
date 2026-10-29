import 'dart:io' as io;
import 'dart:typed_data';
// CacheManager's public FileSystem interface uses package:file's File type.
// ignore: depend_on_referenced_packages
import 'package:file/file.dart' as fs;
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingyu/ui/image_cache_budget.dart';
import 'package:yingyu/core/image_references.dart';

class TestFiles implements FileSystem {
  TestFiles(this.path);
  final String path;
  @override
  Future<fs.File> createFile(String name) async {
    final directory = const LocalFileSystem().directory(path);
    await directory.create(recursive: true);
    return directory.childFile(name);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late io.Directory root;
  late ImageCacheBudget budget;
  late BudgetCacheManager posters, artwork;
  var downloads = 0;
  BudgetCacheManager manager(String name) => BudgetCacheManager(
    Config(
      name,
      fileService: HttpFileService(
        httpClient: MockClient((_) async {
          downloads++;
          return http.Response.bytes(
            Uint8List(60),
            200,
            headers: {'cache-control': 'max-age=86400'},
          );
        }),
      ),
      fileSystem: TestFiles('${root.path}/$name'),
      repo: JsonCacheInfoRepository.withFile(
        io.File('${root.path}/$name.json'),
      ),
      maxNrOfCacheObjects: 100000,
      stalePeriod: const Duration(days: 36500),
    ),
    budget,
    isArtwork: name == 'artwork',
  );
  setUp(() async {
    downloads = 0;
    root = await io.Directory.systemTemp.createTemp('yingyu-quota-test-');
    budget = ImageCacheBudget(limitBytes: 150);
    posters = manager('posters');
    artwork = manager('artwork');
  });
  tearDown(() async {
    await posters.dispose();
    await artwork.dispose();
    budget.dispose();
    expect(
      root.absolute.path.startsWith(io.Directory.systemTemp.absolute.path),
      true,
    );
    expect(
      root.path
          .split(io.Platform.pathSeparator)
          .last
          .startsWith('yingyu-quota-test-'),
      true,
    );
    await root.delete(recursive: true);
  });
  Future<fs.File> put(BudgetCacheManager manager, String key, int size) async {
    final file = await manager.putFile(
      'https://fixture.invalid/$key',
      Uint8List(size),
      key: key,
    );
    final info = await manager.getFileFromCache(key);
    await budget.record(manager, info!, key);
    return file;
  }

  test(
    'actual cache stream enforces quota and serves repeat requests from disk',
    () async {
      const url = 'https://fixture.invalid/poster';
      await posters.getFileStream(url).toList();
      expect(budget.usedBytes, 60);
      expect(downloads, 1);
      await posters.getFileStream(url).toList();
      expect(downloads, 1);
      await posters.emptyCache();
      expect(budget.usedBytes, 0);
      await posters.getFileStream(url).toList();
      expect(downloads, 2);
      expect(budget.usedBytes, 60);
    },
  );
  test(
    'orphan cleanup targets actual indexed files and keeps referenced neighbors without HTTP',
    () async {
      final a = await put(posters, 'removed-key', 50);
      final b = await put(posters, 'shared-key', 50);
      final candidates = {
        ImageReferences.digest('removed-key'),
        ImageReferences.digest('shared-key'),
      };
      await budget.removeUnreferenced(
        candidates,
        (key) => key == ImageReferences.digest('removed-key'),
      );
      expect(await a.exists(), false);
      expect(await b.exists(), true);
      expect(await posters.getFileFromCache('removed-key'), isNull);
      expect(budget.usedBytes, 50);
      expect(downloads, 0);
    },
  );

  test(
    'opted-in cleanup expires old detail artwork but retains wall posters',
    () async {
      budget.autoCleanDays = 30;
      final file = await artwork.putFile(
        'https://fixture.invalid/old',
        Uint8List(30),
        key: 'old',
      );
      await file.setLastModified(
        DateTime.now().subtract(const Duration(days: 31)),
      );
      final wall = await posters.putFile(
        'https://fixture.invalid/wall',
        Uint8List(30),
        key: 'wall',
      );
      await wall.setLastModified(
        DateTime.now().subtract(const Duration(days: 60)),
      );
      await budget.initialize();
      expect(await file.exists(), false);
      expect(await artwork.getFileFromCache('old'), null);
      expect(await wall.exists(), true);
    },
  );

  test(
    'newer artwork is evicted before an older wall poster across separate directories',
    () async {
      final a = await put(posters, 'first', 60);
      final b = await put(artwork, 'second', 60);
      final c = await put(posters, 'third', 60);
      expect(await a.exists(), true);
      expect(await b.exists(), false);
      expect(await c.exists(), true);
      expect(await artwork.getFileFromCache('second'), null);
      expect(budget.usedBytes, 120);
      expect(a.parent.path, isNot(b.parent.path));
    },
  );
  test(
    'cache hit touches LRU; changing limit really deletes excess bytes',
    () async {
      final a = await put(posters, 'first', 60);
      final b = await put(artwork, 'second', 60);
      await budget.record(
        posters,
        (await posters.getFileFromCache('first'))!,
        'first',
      );
      await put(posters, 'third', 60);
      expect(await a.exists(), true);
      expect(await b.exists(), false);
      await budget.setLimit(65);
      expect(budget.usedBytes, 60);
      expect(await a.exists(), false);
    },
  );
  test(
    'clear is scoped to selected cache; file and metadata are both removed',
    () async {
      final a = await put(posters, 'poster', 60);
      final b = await put(artwork, 'background', 60);
      await posters.emptyCache();
      expect(await a.exists(), false);
      expect(await posters.getFileFromCache('poster'), null);
      expect(await b.exists(), true);
      expect(budget.usedBytes, 60);
    },
  );
  test('startup accounts for orphan files and trims them from disk', () async {
    final old = await posters.config.fileSystem.createFile('orphan.jpg');
    await old.writeAsBytes(Uint8List(200));
    await budget.setLimit(150);
    expect(await old.exists(), false);
    expect(budget.usedBytes, 0);
  });
  test(
    'recently viewed artwork moves behind older artwork; posters are last',
    () async {
      await budget.setLimit(300);
      final wall = await put(posters, 'wall', 60);
      final first = await put(artwork, 'first', 60);
      final second = await put(artwork, 'second', 60);
      // Ensure distinct access times. Same-timestamp entries intentionally use
      // a stable filename tie-break, so they cannot test "viewed later".
      final previousAccess = await second.lastModified();
      while (!DateTime.now().isAfter(previousAccess)) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await budget.record(
        artwork,
        (await artwork.getFileFromCache('first'))!,
        'first',
      );
      await budget.setLimit(120);
      expect(await second.exists(), false);
      expect(await first.exists(), true);
      expect(await wall.exists(), true);
      await budget.setLimit(60);
      expect(await first.exists(), false);
      expect(await wall.exists(), true);
      expect(budget.usedBytes, 60);
    },
  );
  test(
    'startup uses persisted dates and category for orphan and indexed files',
    () async {
      final files = <fs.File>[];
      for (final entry in [
        (posters, 'wall', 20),
        (artwork, 'old-art', 10),
        (artwork, 'new-art', 1),
      ]) {
        final file = await entry.$1.config.fileSystem.createFile(
          '${entry.$2}.jpg',
        );
        await file.writeAsBytes(Uint8List(60));
        await file.setLastModified(
          DateTime.now().subtract(Duration(days: entry.$3)),
        );
        files.add(file);
      }
      await budget.initialize();
      expect(await files[0].exists(), true);
      expect(await files[1].exists(), false);
      expect(await files[2].exists(), true);
      expect(budget.usedBytes, 120);
    },
  );
}
