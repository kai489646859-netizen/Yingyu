import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/version_groups.dart';
import 'package:yingyu/playback/intro_editor.dart';
import 'package:yingyu/playback/episode_actions.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/library.dart' show MediaCard;
import 'package:yingyu/ui/library_layout.dart';
import 'package:yingyu/ui/personal_library.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/version_group.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'personal_features_test.dart' show featureMovie, featureEpisode;
import 'player_episode_menu_test.dart' show fonts;
import 'playback_test.dart' show FakeBackend;
import 'offline_settle.dart';

void main() {
  late AppStore store;
  late EmbyClient api;
  late BrowseRepository browse;
  final calls = <String>[];
  final movies = [
    featureMovie('a', name: '远山之旅'),
    featureMovie('b', name: '远山之旅'),
  ];
  MediaItem detail(MediaItem item) => MediaItem({
    ...item.data,
    'MediaSources': [
      {
        'Id': 'source-${item.id}',
        'Name': item.id == 'a' ? '导演剪辑版' : '院线版',
        'Path': 'do-not-cache',
        'MediaStreams': [
          {
            'Type': 'Video',
            'Codec': 'hevc',
            'Width': item.id == 'a' ? 3840 : 1920,
            'Height': item.id == 'a' ? 2160 : 1080,
          },
        ],
      },
    ],
  });
  setUp(() async {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    calls.clear();
    api = EmbyClient(
      client: MockClient((r) async {
        calls.add(r.url.path);
        if (r.url.path.endsWith('/Views')) {
          return response(
            '{"Items":[{"Id":"library","Type":"CollectionFolder","CollectionType":"movies"}]}',
            200,
          );
        }
        if (r.url.path.endsWith('/Items')) {
          return response(
            jsonEncode({
              'Items': movies.map((e) => e.data).toList(),
              'TotalRecordCount': movies.length,
            }),
            200,
          );
        }
        final item = movies
            .where((m) => r.url.path.endsWith('/${m.id}'))
            .firstOrNull;
        if (item == null) {
          throw StateError('Unexpected request; media access forbidden');
        }
        return response(jsonEncode(detail(item).data), 200);
      }),
    )..session = syntheticSession();
    browse = BrowseRepository(
      api,
      store.browseCache,
      BrowsePreferences(store.prefs),
      spacing: Duration.zero,
    );
  });
  tearDown(() {
    browse.dispose();
    browse.preferences.dispose();
    api.close();
    store.log.dispose();
    store.dispose();
  });

  for (final display in LibraryDisplay.values) {
    testWidgets('narrow ${display.name} separates version and episode badges', (
      tester,
    ) async {
      await fonts();
      final group = VersionGroup(accountKey(api.session!), [
        for (final movie in movies)
          MediaItem({
            ...movie.data,
            'Type': 'Series',
            'RecursiveItemCount': 120,
          }),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: display == LibraryDisplay.posters ? 90 : 300,
                child: display == LibraryDisplay.posters
                    ? LibraryPosterCard(
                        item: group,
                        api: api,
                        onTap: () {},
                        active: false,
                      )
                    : MediaCard(
                        item: group,
                        api: api,
                        onTap: () {},
                        active: false,
                      ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final versions = tester.getRect(find.text('2 个版本'));
      final episodes = tester.getRect(find.text('120 集'));
      expect(versions.overlaps(episodes), false);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets(
      'library ${display.name} groups same TMDB without changing underlying items',
      (tester) async {
        MediaItem? selected;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryPage(
                api: api,
                browse: browse,
                display: display,
                onItem: (value) async {
                  selected = value;
                },
              ),
            ),
          ),
        );
        await settleOffline(tester);
        for (var i = 0; i < 100 && find.text('远山之旅').evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(
          find.text('远山之旅'),
          findsOneWidget,
          reason:
              'calls=$calls; labels=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
        );
        expect(find.text('2 个版本'), findsOneWidget);
        await tester.tap(find.text('远山之旅'));
        await tester.pump();
        expect(selected, isA<VersionGroup>());
        expect((selected as VersionGroup).versions.map((e) => e.id), [
          'a',
          'b',
        ]);
        expect(browse.peekSharedCatalogue(null)!.items.length, 2);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'version chooser returns exact selected item, reuses cache, never plays or fetches artwork',
    (tester) async {
      MediaItem? chosen;
      final group =
          groupVersions(movies, api.session!).items.single as VersionGroup;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                chosen = await Navigator.push<MediaItem>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        VersionChooser(group: group, api: api, browse: browse),
                  ),
                );
              },
              child: const Text('选择版本'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择版本'));
      await settleOffline(tester);
      expect(find.textContaining('4K'), findsOneWidget);
      expect(find.textContaining('1080p'), findsOneWidget);
      await tester.tap(find.text('2. 远山之旅'));
      await settleOffline(tester);
      expect(chosen!.id, 'b');
      expect(chosen!.resume, Duration.zero);
      final count = calls.length;
      await tester.tap(find.text('选择版本'));
      await settleOffline(tester);
      expect(calls.length, count);
      expect(
        jsonEncode(browse.peek('detail:a')!.items.single.data),
        isNot(contains('do-not-cache')),
      );
      expect(calls.every((p) => p.endsWith('/a') || p.endsWith('/b')), true);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'dismissed chooser stops subsequent reads and stale account cannot choose',
    (tester) async {
      final held = Completer<void>();
      final owner = api.session!;
      api.close();
      api = EmbyClient(
        client: MockClient((r) async {
          calls.add(r.url.path);
          await held.future;
          return response(jsonEncode(detail(movies.first).data), 200);
        }),
      )..session = owner;
      browse.dispose();
      browse = BrowseRepository(
        api,
        store.browseCache,
        BrowsePreferences(store.prefs),
        spacing: Duration.zero,
      );
      final group = VersionGroup(accountKey(owner), movies);
      await tester.pumpWidget(
        MaterialApp(
          home: VersionChooser(group: group, api: api, browse: browse),
        ),
      );
      await tester.pump();
      expect(calls.length, 1);
      await tester.pumpWidget(const SizedBox());
      api.session = syntheticSession();
      held.complete();
      await settleOffline(tester);
      expect(calls.length, 1);
      expect(tester.takeException(), null);
    },
  );

  for (final size in [
    const Size(412, 915),
    const Size(915, 412),
    const Size(900, 1280),
    const Size(1280, 800),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('personal/version/intro layout $size $brightness', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await fonts();
        final key = GlobalKey();
        Future<void> show(Widget child) async {
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: child,
              ),
            ),
          );
          await settleOffline(tester);
        }

        Future<void> shot(String name) async {
          expect(tester.takeException(), null);
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/$appVersion-feature-$name-${size.width.toInt()}-${brightness.name}.png',
            );
            file.parent.createSync(recursive: true);
            file.writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await show(
          Scaffold(
            body: SafeArea(
              child: SaveMediaButtons(
                library: store.personal,
                account: api.session!,
                item: movies.first,
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('save-watchlist')));
        await settleOffline(tester);
        await tester.tap(find.byKey(const ValueKey('save-favorites')));
        await settleOffline(tester);
        expect(find.text('已加入想看'), findsOneWidget);
        expect(find.text('已收藏'), findsOneWidget);
        MediaItem? selected;
        await show(
          SavedMediaPage(
            library: store.personal,
            account: api.session!,
            api: api,
            list: SavedList.watchlist,
            onItem: (v) async {
              selected = v;
            },
          ),
        );
        await shot('saved');
        await tester.tap(find.text('远山之旅'));
        expect(selected!.id, 'a');
        await tester.tap(find.byTooltip('移出想看'));
        await settleOffline(tester);
        expect(
          store.personal.items(api.session!, SavedList.watchlist),
          isEmpty,
        );
        expect(
          store.personal.items(api.session!, SavedList.favorites).length,
          1,
        );
        await show(
          VersionChooser(
            group: VersionGroup(accountKey(api.session!), movies),
            api: api,
            browse: browse,
          ),
        );
        expect(find.textContaining('4K'), findsOneWidget);
        await shot('versions');
        final backend = FakeBackend();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: featureEpisode('1'),
          backend: backend,
        );
        await show(IntroEditor(session: session));
        await shot('intro');
        if (brightness == Brightness.dark &&
            (size.width == 412 || size.width == 1280)) {
          final enable = find.byKey(const ValueKey('skip-credits-enabled'));
          await tester.scrollUntilVisible(
            enable,
            80,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(enable);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          final field = find.byKey(const ValueKey('skip-credits-remaining'));
          await tester.scrollUntilVisible(
            field,
            80,
            scrollable: find.byType(Scrollable).first,
          );
          await shot('intro-credits-edit');
        }
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await tester.pump();
        final editIntro = find.byKey(const ValueKey('skip-edit-intro'));
        await tester.scrollUntilVisible(
          editIntro,
          80,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(editIntro);
        await tester.pump();
        for (final field in {
          'skip-intro-start': '2:00',
          'skip-intro-end': '1:00',
        }.entries) {
          final finder = find.byKey(ValueKey(field.key));
          await tester.scrollUntilVisible(
            finder,
            80,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.enterText(finder, field.value);
        }
        await tester.scrollUntilVisible(
          find.text('保存'),
          80,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('保存'));
        await settleOffline(tester);
        expect(find.textContaining('片头结束时间必须'), findsOneWidget);
        if (brightness == Brightness.dark && size.width == 1280) {
          await store.personal.setSkipRule(
            api.session!,
            session.item,
            SkipScope.season,
            const SkipRule(
              intro: IntroRange(Duration.zero, Duration(seconds: 90)),
              autoIntro: true,
            ),
            const Duration(minutes: 10),
          );
          backend.snapshot = const PlaybackSnapshot(
            duration: Duration(minutes: 10),
            playing: true,
          );
          session.ready = true;
          session.loading = false;
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: Scaffold(
                  backgroundColor: Colors.black,
                  body: Stack(
                    children: [
                      EpisodeActions(
                        session: session,
                        next: null,
                        enabled: true,
                        controls: false,
                        onNext: (_) async =>
                            throw StateError('preview cannot open media'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(find.text('3 秒后跳过片头'), findsOneWidget);
          await shot('intro-auto-prompt');
          await tester.tap(find.text('本次不跳'));
          await tester.pump();
          expect(find.text('跳过片头'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
        await session.close();
        session.dispose();
      });
    }
  }
}
