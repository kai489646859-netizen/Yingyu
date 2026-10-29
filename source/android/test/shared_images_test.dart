import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/image_identity.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/image_cache_budget.dart';
import 'package:yingyu/ui/poster_art.dart';
import 'accounts_test.dart' show accountFixture;
import 'image_budget_test.dart' show TestFiles;

MediaItem imageFixture(
  String id, {
  String tmdb = '550',
  String type = 'Movie',
  String tag = 'tag-a',
  String name = 'A 4K',
}) => MediaItem({
  'Id': id,
  'Type': type,
  'Name': name,
  'ProviderIds': {'Tmdb': tmdb},
  'ImageTags': {'Primary': tag},
  'BackdropImageTags': ['$tag-backdrop'],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late EmbyClient a, b;
  setUp(() {
    SharedImageIdentity.reset();
    a = EmbyClient()..session = accountFixture('a');
    b = EmbyClient()..session = accountFixture('b', server: 'unrelated');
  });
  tearDown(() {
    a.close();
    b.close();
    SharedImageIdentity.reset();
  });
  test(
    'same TMDB shares across every account, server, name, ID, tag and resource version',
    () {
      final urlA = a.imageUrl(imageFixture('source-4k'));
      final urlB = b.imageUrl(
        imageFixture('source-1080', tag: 'other-art', name: 'different name'),
      );
      expect(urlA, isNot(urlB));
      expect(SharedImageIdentity.key(urlA), SharedImageIdentity.key(urlB));
      expect(Uri.parse(urlB).queryParameters['api_key'], b.session!.token);
      expect(SharedImageIdentity.key(urlB), isNot(contains(b.session!.token)));
      expect(
        SharedImageIdentity.key(urlB),
        isNot(contains(b.session!.base.host)),
      );
    },
  );
  test(
    'movie and TV numeric IDs differ; poster and backdrop never collide',
    () {
      final movie = a.imageUrl(imageFixture('film'));
      final tv = b.imageUrl(imageFixture('tv', type: 'Series'));
      final backdrop = a.imageUrl(imageFixture('film'), backdrop: true);
      expect(
        SharedImageIdentity.key(movie),
        isNot(SharedImageIdentity.key(tv)),
      );
      expect(
        SharedImageIdentity.key(movie),
        isNot(SharedImageIdentity.key(backdrop, artwork: true)),
      );
    },
  );
  test(
    'same title without TMDB cannot merge unrelated servers; missing tags cannot merge tokens',
    () {
      final first = imageFixture('same', tmdb: '');
      expect(
        SharedImageIdentity.key(a.imageUrl(first)),
        isNot(SharedImageIdentity.key(b.imageUrl(first))),
      );
      final missing = imageFixture('new-id', tmdb: '', tag: '');
      b.session = accountFixture('b');
      expect(
        SharedImageIdentity.key(a.imageUrl(missing)),
        isNot(SharedImageIdentity.key(b.imageUrl(missing))),
      );
    },
  );
  test(
    'person identity is shared across resources and separated from movie IDs',
    () {
      final person = a.imageUrl(
        imageFixture('actor', type: 'Person', tmdb: '10'),
      );
      final same = b.imageUrl(
        imageFixture(
          'other-actor-id',
          type: 'Person',
          tmdb: '10',
          tag: 'another',
        ),
      );
      final movie = a.imageUrl(imageFixture('movie', tmdb: '10'));
      expect(SharedImageIdentity.key(person), SharedImageIdentity.key(same));
      expect(
        SharedImageIdentity.key(person),
        isNot(SharedImageIdentity.key(movie)),
      );
    },
  );
  test('same server image with same tag shares across tokens without TMDB', () {
    b.session = accountFixture('b');
    final first = imageFixture('same', tmdb: '');
    expect(
      SharedImageIdentity.key(a.imageUrl(first)),
      SharedImageIdentity.key(b.imageUrl(first)),
    );
  });
  test(
    'episode uses actual series TMDB and never treats episode TMDB as series ID',
    () {
      final series = imageFixture('series', type: 'Series', tmdb: '10');
      final episode = MediaItem({
        'Id': 'ep',
        'Type': 'Episode',
        'SeriesId': 'series',
        'ProviderIds': {'Tmdb': '999'},
        'SeriesPrimaryImageTag': 'tag-a',
      });
      final poster = posterUrl(a, episode, series: series)!;
      expect(SharedImageIdentity.key(poster), contains('tv:10:poster'));
      expect(episode.id, 'ep');
      expect(episode.data['ProviderIds'], {'Tmdb': '999'});
    },
  );
  test(
    'display cache keeps only valid TMDB identity, never source URL or credentials',
    () {
      final cached = displayMetadata({
        ...imageFixture('x').data,
        'ProviderIds': {'Tmdb': '550', 'private-token': 'secret'},
        'Path': 'private-media',
      });
      expect(cached['ProviderIds'], {'Tmdb': '550'});
      expect(cached.containsKey('Path'), false);
      expect(SharedImageIdentity.work(MediaItem(cached)), 'movie:550');
      for (final invalid in [
        '',
        '-1',
        '0',
        '1/2',
        'https://example.invalid',
        'abc',
      ]) {
        expect(
          SharedImageIdentity.work(imageFixture('x', tmdb: invalid)),
          isNull,
        );
      }
    },
  );
  test('cached actor metadata retains only verified identity fields', () {
    final cached = displayMetadata({
      'Id': 'm',
      'Type': 'Movie',
      'People': [
        {
          'Id': 'p',
          'Name': 'Actor',
          'Type': 'Actor',
          'PrimaryImageTag': 'tag',
          'ProviderIds': {'Tmdb': '123', 'secret': 'token'},
          'Path': 'private',
        },
      ],
    });
    final person = (cached['People'] as List).single as Map;
    expect(person['ProviderIds'], {'Tmdb': '123'});
    expect(person.containsKey('Path'), false);
  });
  test('changed or removed metadata cannot inherit a stale work identity', () {
    final series = imageFixture('series', type: 'Series', tmdb: '10');
    a.imageUrl(series);
    final episode = MediaItem({
      'Id': 'episode',
      'Type': 'Episode',
      'SeriesId': 'series',
      'SeriesPrimaryImageTag': 'tag-a',
    });
    expect(
      SharedImageIdentity.key(posterUrl(a, episode)!),
      contains('tmdb:v1:tv:10:'),
    );
    final changedTag = MediaItem({
      ...episode.data,
      'SeriesPrimaryImageTag': 'new',
    });
    expect(
      SharedImageIdentity.key(posterUrl(a, changedTag)!),
      isNot(contains('tmdb:')),
    );
    final removed = MediaItem({
      ...series.data,
      'ProviderIds': <String, String>{},
    });
    expect(
      SharedImageIdentity.key(a.imageUrl(removed)),
      isNot(contains('tmdb:')),
    );
    expect(
      SharedImageIdentity.key(posterUrl(a, episode)!),
      isNot(contains('tmdb:')),
    );
  });
  test(
    'arbitrary signed URLs do not lose parameters or authentication in their key',
    () {
      const url =
          'https://one.invalid/emby/Items/x/Images/Primary?api_key=one&sig=opaque&tag=known';
      expect(SharedImageIdentity.key(url), url);
    },
  );

  group('actual disk files and cache repository', () {
    late Directory root;
    late ImageCacheBudget budget;
    late BudgetCacheManager cache;
    late int network;
    BudgetCacheManager open() => BudgetCacheManager(
      Config(
        'shared-test',
        fileSystem: TestFiles('${root.path}/images'),
        repo: JsonCacheInfoRepository.withFile(File('${root.path}/cache.json')),
        fileService: HttpFileService(
          httpClient: MockClient((_) async {
            network++;
            return http.Response.bytes(
              Uint8List(100),
              200,
              headers: {
                'cache-control': 'max-age=0',
                'content-type': 'image/png',
              },
            );
          }),
        ),
        maxNrOfCacheObjects: 1000,
        stalePeriod: const Duration(days: 36500),
      ),
      budget,
    );
    setUp(() async {
      root = await Directory.systemTemp.createTemp('yingyu-shared-image-');
      network = 0;
      budget = ImageCacheBudget(limitBytes: 4096);
      cache = open();
    });
    tearDown(() async {
      await cache.dispose();
      budget.dispose();
      expect(
        root.absolute.path.startsWith(Directory.systemTemp.absolute.path),
        true,
      );
      expect(
        root.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('yingyu-shared-image-'),
        true,
      );
      await root.delete(recursive: true);
    });
    test(
      'cross-server TMDB hit reuses the identical file with zero extra network and bytes',
      () async {
        final first = a.imageUrl(imageFixture('4k'));
        final second = b.imageUrl(imageFixture('1080p', tag: 'other'));
        final one =
            (await cache
                    .getFileStream(first, key: SharedImageIdentity.key(first))
                    .toList())
                .whereType<FileInfo>()
                .last;
        final two =
            (await cache
                    .getFileStream(second, key: SharedImageIdentity.key(second))
                    .toList())
                .whereType<FileInfo>()
                .last;
        expect(two.file.path, one.file.path);
        expect(network, 1);
        expect(budget.usedBytes, 100);
        expect((await cache.config.repo.getAllObjects()).length, 1);
      },
    );
    test(
      'legacy token-keyed image is reindexed in place without redownloading or copying',
      () async {
        final first = a.imageUrl(imageFixture('4k'));
        final legacyFile = await cache.putFile(
          first,
          Uint8List(77),
          key: first,
        );
        final info =
            (await cache
                    .getFileStream(first, key: SharedImageIdentity.key(first))
                    .toList())
                .whereType<FileInfo>()
                .single;
        expect(info.file.path, legacyFile.path);
        expect(network, 0);
        final second = b.imageUrl(imageFixture('1080', tag: 'new-tag'));
        final hit = await cache
            .getFileStream(second, key: SharedImageIdentity.key(second))
            .toList();
        expect(hit.whereType<FileInfo>().single.file.path, legacyFile.path);
        expect((await cache.config.repo.getAllObjects()).length, 1);
        expect(budget.usedBytes, 77);
      },
    );
    test(
      'existing actor portrait promotes in place and is reused across servers',
      () async {
        final fallback = a.imageUrl(
          imageFixture('actor', type: 'Person', tmdb: ''),
        );
        final file = await cache.putFile(
          fallback,
          Uint8List(77),
          key: SharedImageIdentity.key(fallback),
        );
        final known = a.imageUrl(
          imageFixture('actor', type: 'Person', tmdb: '123'),
        );
        final one =
            (await cache
                    .getFileStream(known, key: SharedImageIdentity.key(known))
                    .toList())
                .whereType<FileInfo>()
                .single;
        final cross = b.imageUrl(
          imageFixture('other', type: 'Person', tmdb: '123', tag: 'other'),
        );
        final two =
            (await cache
                    .getFileStream(cross, key: SharedImageIdentity.key(cross))
                    .toList())
                .whereType<FileInfo>()
                .single;
        expect(one.file.path, file.path);
        expect(two.file.path, file.path);
        expect(network, 0);
        expect(budget.usedBytes, 77);
        expect((await cache.config.repo.getAllObjects()).length, 1);
      },
    );
    test(
      'shared disk cache survives restart and remains reusable after HTTP expiry',
      () async {
        final first = a.imageUrl(imageFixture('4k'));
        await cache
            .getFileStream(first, key: SharedImageIdentity.key(first))
            .toList();
        await cache.dispose();
        budget.dispose();
        SharedImageIdentity.reset();
        budget = ImageCacheBudget(limitBytes: 4096);
        cache = open();
        final second = b.imageUrl(imageFixture('1080', tag: 'other'));
        await cache
            .getFileStream(second, key: SharedImageIdentity.key(second))
            .toList();
        expect(network, 1);
        expect(budget.usedBytes, 100);
      },
    );
    test(
      'later TMDB metadata promotes a new fallback file without downloading again',
      () async {
        final first = a.imageUrl(imageFixture('later-id', tmdb: ''));
        final original =
            (await cache
                    .getFileStream(first, key: SharedImageIdentity.key(first))
                    .toList())
                .whereType<FileInfo>()
                .single;
        expect(network, 1);
        // The legacy index was already loaded by the first request. Metadata now
        // learns TMDB through the ordinary browse refresh in the same process.
        final known = a.imageUrl(imageFixture('later-id'));
        final promoted =
            (await cache
                    .getFileStream(known, key: SharedImageIdentity.key(known))
                    .toList())
                .whereType<FileInfo>()
                .single;
        final other = b.imageUrl(imageFixture('remote-id', tag: 'elsewhere'));
        final shared =
            (await cache
                    .getFileStream(other, key: SharedImageIdentity.key(other))
                    .toList())
                .whereType<FileInfo>()
                .single;
        expect(promoted.file.path, original.file.path);
        expect(shared.file.path, original.file.path);
        expect(network, 1);
        expect(budget.usedBytes, 100);
        expect((await cache.config.repo.getAllObjects()).length, 1);
      },
    );
    test(
      'explicit clearing removes shared file and next visible request can fetch fresh artwork',
      () async {
        final first = a.imageUrl(imageFixture('4k'));
        final key = SharedImageIdentity.key(first);
        await cache.getFileStream(first, key: key).toList();
        await cache.emptyCache();
        expect(budget.usedBytes, 0);
        final second = b.imageUrl(imageFixture('1080', tag: 'other'));
        await cache
            .getFileStream(second, key: SharedImageIdentity.key(second))
            .toList();
        expect(network, 2);
        expect(budget.usedBytes, 100);
      },
    );
  });
}
