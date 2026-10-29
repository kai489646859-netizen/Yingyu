import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingyu/ui/image_cache_budget.dart';
import 'package:yingyu/ui/persistent_image_files.dart';
import 'image_budget_test.dart' show TestFiles;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const cacheKey = 'yingyu-posters-v1';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('yingyu-persistent-image-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async =>
              '${root.path}/${call.method == 'getTemporaryDirectory' ? 'temporary' : 'support'}',
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    expect(
      root.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      true,
    );
    expect(
      root.uri.pathSegments
          .where((p) => p.isNotEmpty)
          .last
          .startsWith('yingyu-persistent-image-'),
      true,
    );
    await root.delete(recursive: true);
  });
  test(
    'upgrade moves existing images with their index and survives temporary cache removal',
    () async {
      var network = 0;
      final budget = ImageCacheBudget(limitBytes: 1024);
      BudgetCacheManager open(FileSystem files) => BudgetCacheManager(
        Config(
          cacheKey,
          fileSystem: files,
          repo: JsonCacheInfoRepository.withFile(
            File('${root.path}/index.json'),
          ),
          stalePeriod: const Duration(days: 36500),
          maxNrOfCacheObjects: 100000,
          fileService: HttpFileService(
            httpClient: MockClient((_) async {
              network++;
              return http.Response.bytes(Uint8List(60), 200);
            }),
          ),
        ),
        budget,
      );
      var cache = open(TestFiles('${root.path}/temporary/$cacheKey'));
      final old = await cache.putFile(
        'https://fixture.invalid/persistent',
        Uint8List(77),
        key: 'image',
      );
      final oldTime = DateTime.now().subtract(const Duration(days: 80));
      await old.setLastModified(oldTime);
      final oldName = old.basename;
      await cache.dispose();
      cache = open(PersistentImageFiles(cacheKey));
      final hit = await cache.sharedFile(
        'https://fixture.invalid/persistent',
        'image',
      );
      expect(hit, isNotNull);
      expect(hit!.file.basename, oldName);
      expect(await hit.file.readAsBytes(), Uint8List(77));
      expect(hit.file.path, contains('support'));
      expect(
        (await hit.file.lastModified()).difference(oldTime).inSeconds.abs(),
        lessThan(2),
      );
      expect(await old.exists(), false);
      expect(network, 0);
      expect((await cache.config.repo.getAllObjects()).length, 1);
      await cache.dispose();
      final temporary = Directory('${root.path}/temporary');
      expect(temporary.absolute.path.startsWith(root.absolute.path), true);
      await temporary.delete(recursive: true);
      cache = open(PersistentImageFiles(cacheKey));
      final again = await cache.sharedFile(
        'https://fixture.invalid/persistent',
        'image',
      );
      expect(again!.file.path, hit.file.path);
      expect(network, 0);
      await cache.dispose();
      budget.dispose();
    },
  );
  test(
    'partial migration resumes and never overwrites a persistent image',
    () async {
      final old = Directory('${root.path}/temporary/$cacheKey');
      final current = Directory('${root.path}/support/yingyu-images/$cacheKey');
      await old.create(recursive: true);
      await current.create(recursive: true);
      await File('${old.path}/pending.png').writeAsString('old');
      await File('${old.path}/same.png').writeAsString('legacy');
      await File('${current.path}/same.png').writeAsString('new');
      final fs = PersistentImageFiles(cacheKey);
      final results = await Future.wait(
        List.generate(8, (_) => fs.createFile('pending.png')),
      );
      expect(results.map((f) => f.path).toSet().length, 1);
      expect(await results.first.readAsString(), 'old');
      expect(await File('${old.path}/pending.png').exists(), false);
      expect(await (await fs.createFile('same.png')).readAsString(), 'new');
      expect(await File('${old.path}/same.png').readAsString(), 'legacy');
    },
  );
  for (final days in [0, 15, 30, 60]) {
    test(
      'selected cleanup $days days retains posters and expires only unused artwork',
      () async {
        final budget = ImageCacheBudget(limitBytes: 1024, autoCleanDays: days);
        BudgetCacheManager open(String name) => BudgetCacheManager(
          Config(
            name,
            fileSystem: TestFiles('${root.path}/$name'),
            repo: JsonCacheInfoRepository.withFile(
              File('${root.path}/$name.json'),
            ),
            stalePeriod: const Duration(days: 36500),
            maxNrOfCacheObjects: 100000,
          ),
          budget,
          isArtwork: name == 'art',
        );
        final wall = open('wall'), art = open('art');
        final expected = <File, bool>{};
        for (final cache in [wall, art]) {
          for (final age in [1, 16, 31, 61]) {
            final file = await cache.putFile(
              'https://fixture.invalid/$age',
              Uint8List(10),
              key: '$age',
            );
            await file.setLastModified(
              DateTime.now().subtract(Duration(days: age)),
            );
            expected[File(file.path)] =
                !cache.isArtwork || days == 0 || age < days;
          }
        }
        await budget.initialize();
        for (final e in expected.entries) {
          expect(await e.key.exists(), e.value, reason: e.key.path);
        }
        await wall.dispose();
        await art.dispose();
        budget.dispose();
      },
    );
  }
}
