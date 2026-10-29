import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/core/version_groups.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession;

MediaItem featureMovie(
  String id, {
  String tmdb = '26',
  String type = 'Movie',
  String name = '同一影片',
}) => MediaItem({
  'Id': id,
  'Name': name,
  'Type': type,
  'ProviderIds': {'Tmdb': tmdb},
  'ProductionYear': 2026,
  'UserData': {'PlaybackPositionTicks': id == 'a' ? 600000000 : 0},
});
MediaItem featureEpisode(
  String id, {
  String series = 'series',
  String season = 's1',
}) => MediaItem({
  'Id': id,
  'Name': '第 $id 集',
  'Type': 'Episode',
  'SeriesId': series,
  'SeriesName': '合成剧集',
  'SeasonId': season,
  'ParentIndexNumber': 1,
  'IndexNumber': int.tryParse(id),
  'RunTimeTicks': 6000000000,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late PersonalLibrary library;
  final account = syntheticSession();
  final otherUser = Session(
    base: account.base,
    userId: 'another',
    token: 'test',
    username: '另一账号',
    deviceId: 'test',
  );
  final otherServer = Session(
    base: Uri.parse('https://another.invalid/emby'),
    userId: account.userId,
    token: 'test',
    username: '同名',
    deviceId: 'test',
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    library = PersonalLibrary(prefs);
  });
  tearDown(() => library.dispose());

  for (final list in SavedList.values) {
    test(
      '${list.name} survives recreation and is isolated by user and server',
      () async {
        await library.setSaved(account, list, featureMovie('a'), true);
        expect(library.items(otherUser, list), isEmpty);
        expect(library.items(otherServer, list), isEmpty);
        final reload = PersonalLibrary(prefs);
        expect(reload.items(account, list).single.id, 'a');
        expect(reload.contains(account, list, 'b'), false);
        await library.setSaved(account, list, featureMovie('a'), false);
        expect(PersonalLibrary(prefs).items(account, list), isEmpty);
        reload.dispose();
      },
    );
  }
  test(
    'concurrent updates retain both lists and accounts without merging IDs',
    () async {
      await Future.wait([
        library.setSaved(account, SavedList.watchlist, featureMovie('a'), true),
        library.setSaved(account, SavedList.favorites, featureMovie('b'), true),
        library.setSaved(
          otherUser,
          SavedList.watchlist,
          featureMovie('c'),
          true,
        ),
      ]);
      expect(library.items(account, SavedList.watchlist).single.id, 'a');
      expect(library.items(account, SavedList.favorites).single.id, 'b');
      expect(library.items(otherUser, SavedList.watchlist).single.id, 'c');
    },
  );
  test(
    'persistent collection excludes media URLs credentials paths and streams secrets',
    () async {
      final item = MediaItem({
        ...featureMovie('a').data,
        'Path': 'secret-path',
        'AccessToken': 'secret-token',
        'MediaSources': [
          {
            'Id': 'source',
            'Name': '4K',
            'Path': 'secret-path',
            'DirectStreamUrl': 'secret-url',
            'MediaStreams': [
              {
                'Type': 'Video',
                'Width': 3840,
                'Height': 2160,
                'Codec': 'hevc',
                'Path': 'secret-subtitle',
              },
            ],
          },
        ],
      });
      await library.setSaved(account, SavedList.watchlist, item, true);
      final serialized = prefs.getString(library.storageKey(account))!;
      expect(serialized, isNot(contains('secret-')));
      expect(
        versionDescription(library.items(account, SavedList.watchlist).single),
        contains('4K'),
      );
      expect(displayMetadata(item.data)['MediaSources'], isNotNull);
    },
  );
  test('corrupt personal document is reported and never overwritten', () async {
    await prefs.setString(library.storageKey(account), 'broken');
    expect(
      () => library.items(account, SavedList.watchlist),
      throwsA(isA<AppFailure>()),
    );
    await expectLater(
      library.setSaved(account, SavedList.watchlist, featureMovie('a'), true),
      throwsA(isA<AppFailure>()),
    );
    expect(prefs.getString(library.storageKey(account)), 'broken');
  });
  test(
    'intro belongs to concrete series season and account; removal is durable',
    () async {
      await library.setIntro(
        account,
        featureEpisode('1'),
        const IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
        const Duration(minutes: 10),
      );
      expect(library.intro(account, featureEpisode('2'))?.end.inSeconds, 90);
      expect(library.intro(account, featureEpisode('1', season: 's2')), null);
      expect(
        library.intro(account, featureEpisode('1', series: 'another-version')),
        null,
      );
      expect(library.intro(otherUser, featureEpisode('1')), null);
      expect(library.intro(otherServer, featureEpisode('1')), null);
      expect(
        PersonalLibrary(
          prefs,
        ).intro(account, featureEpisode('2'))?.start.inSeconds,
        10,
      );
      await library.setIntro(
        account,
        featureEpisode('1'),
        null,
        const Duration(minutes: 10),
      );
      expect(library.intro(account, featureEpisode('2')), null);
    },
  );
  for (final times in [(-1, 90), (90, 90), (91, 90), (0, 600), (0, 601)]) {
    test('invalid intro ${times.$1}-${times.$2} cannot be saved', () async {
      await expectLater(
        library.setIntro(
          account,
          featureEpisode('1'),
          IntroRange(Duration(seconds: times.$1), Duration(seconds: times.$2)),
          const Duration(seconds: 600),
        ),
        throwsA(isA<AppFailure>()),
      );
    });
  }
  test(
    'missing season never guesses, intro outside shortened episode is inactive',
    () {
      expect(
        PersonalLibrary.introScope(
          MediaItem({'Type': 'Episode', 'SeriesId': 'series'}),
        ),
        null,
      );
      const range = IntroRange(Duration(seconds: 10), Duration(seconds: 90));
      expect(
        range.contains(
          const Duration(seconds: 10),
          const Duration(seconds: 100),
        ),
        true,
      );
      expect(
        range.contains(
          const Duration(seconds: 90),
          const Duration(seconds: 100),
        ),
        false,
      );
      expect(
        range.contains(
          const Duration(seconds: 20),
          const Duration(seconds: 60),
        ),
        false,
      );
    },
  );
  test('auto next defaults on and explicit off survives upgrade', () async {
    final store = AppStore(prefs);
    expect(store.autoNext, true);
    await store.setAutoNext(true);
    expect(AppStore(prefs).autoNext, true);
    await store.setAutoNext(false);
    expect(store.autoNext, false);
    expect(AppStore(prefs).autoNext, false);
    store.dispose();
  });
  test('TMDB projection preserves each version ID progress and ordering', () {
    final source = prepareCatalog([
      featureMovie('a'),
      featureMovie('b'),
      featureMovie('c', tmdb: '27', name: '另一个'),
    ]);
    final result = groupVersions(source, account);
    expect(result.items.length, 2);
    final grouped = result.items.whereType<VersionGroup>().single;
    expect(grouped.versions.map((e) => e.id), ['a', 'b']);
    expect(grouped.versions[0].resume.inSeconds, 60);
    expect(grouped.versions[1].resume, Duration.zero);
    expect(source.length, 3);
    expect(
      grouped.owner,
      isNot(
        groupVersions(
          source,
          otherUser,
        ).items.whereType<VersionGroup>().single.owner,
      ),
    );
    final text = jsonEncode(grouped.data);
    expect(text, isNot(contains('versions')));
    for (final entry in result.offsets.entries) {
      expect(
        object(result.items[entry.value].data[titleKeysField])['letter'],
        entry.key,
      );
    }
  });
  test(
    'types invalid IDs missing TMDB and same titles never form false groups',
    () {
      final result = groupVersions([
        featureMovie('a'),
        featureMovie('b', type: 'Series'),
        featureMovie('c', type: 'Episode'),
        featureMovie('d', type: 'Episode'),
        for (final id in ['', '0', '-1', 'abc', '26.0'])
          featureMovie('x$id', tmdb: id),
      ], account);
      expect(result.items.length, 9);
      expect(result.items.whereType<VersionGroup>(), isEmpty);
      expect(
        groupVersions([
          featureMovie('a'),
          featureMovie('b', tmdb: '026'),
        ], account).items.single,
        isA<VersionGroup>(),
      );
    },
  );
  test(
    'search and watched filter select matching variants before grouping',
    () {
      final source = prepareCatalog([
        featureMovie('a', name: '影片 4K'),
        featureMovie('b', name: '影片 1080p'),
      ]);
      final result = groupVersions(
        selectCatalog((source, '4K', null)).items,
        account,
      );
      expect(result.items.single.id, 'a');
      expect(result.items.single, isNot(isA<VersionGroup>()));
    },
  );
  test('contradictory TMDB fields never merge two resources', () {
    final ambiguous = MediaItem({
      ...featureMovie('ambiguous').data,
      'ProviderIds': {'Tmdb': '26', 'tmdb': '27'},
    });
    expect(mediaIdentity(ambiguous), null);
    final result = groupVersions([ambiguous, featureMovie('a')], account);
    expect(result.items.length, 2);
    expect(result.items.whereType<VersionGroup>(), isEmpty);
  });
}
