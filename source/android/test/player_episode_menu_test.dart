import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/episode_menu.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

MediaItem episode(int n, [String season = 's2']) => MediaItem({
  'Id': '$season-e$n',
  'Type': 'Episode',
  'Name': '远行的故事 · 第 $n 集',
  'SeriesId': 'series',
  'SeasonId': season,
  'IndexNumber': n,
  'ParentIndexNumber': int.parse(season.substring(1)),
});
final seasons = List.generate(
  3,
  (i) => MediaItem({
    'Id': 's${i + 1}',
    'Type': 'Season',
    'Name': '第 ${i + 1} 季',
    'IndexNumber': i + 1,
  }),
);
http.Response page(List<MediaItem> items, {int? total}) => response(
  jsonEncode({
    'Items': items.map((i) => i.data).toList(),
    'TotalRecordCount': total ?? items.length,
  }),
  200,
);
EmbyClient catalogueApi({List<String>? calls, int count = 150}) => EmbyClient(
  client: MockClient((r) async {
    calls?.add(r.url.path);
    if (r.url.path.endsWith('/Seasons')) return page(seasons);
    if (r.url.path.endsWith('/Episodes')) {
      return page(
        List.generate(
          count,
          (i) => episode(i + 1, r.url.queryParameters['SeasonId']!),
        ),
      );
    }
    fail(
      'Picker must not request media, artwork or playback info: ${r.url.path}',
    );
  }),
)..session = syntheticSession();

Future<void> fonts() async {
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      ))
      .load();
  final path = Platform.environment['YINGYU_TEST_FONT'];
  if (path != null) {
    final bytes = ByteData.sublistView(File(path).readAsBytesSync());
    for (final name in [
      'Roboto',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
    ]) {
      await (FontLoader(name)..addFont(Future.value(bytes))).load();
    }
  }
}

Future<void> launch(
  WidgetTester tester,
  EpisodeMenuData data,
  MediaItem current, {
  Brightness brightness = Brightness.dark,
  GlobalKey? capture,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: capture,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showSurface<MediaItem>(
                  context,
                  playerMenu: true,
                  (_) => EpisodeMenu(current: current, data: data),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'movie keeps its tools and episode tools fit narrow and wide players',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final width in [320.0, 390.0, 412.0, 440.0, 800.0]) {
        tester.view.physicalSize = Size(width, 800);
        for (final episodic in [false, true]) {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: PlayerChrome(
                  title: '合成影片',
                  visible: true,
                  ready: true,
                  playing: true,
                  position: Duration.zero,
                  duration: const Duration(minutes: 20),
                  onBack: () {},
                  onToggle: () {},
                  onSeekBack: () {},
                  onSeekForward: () {},
                  onMenu: () {},
                  onScrubStart: () {},
                  onScrub: (_) {},
                  onScrubEnd: (_) {},
                  onAudio: () {},
                  onSubtitles: () {},
                  onRate: () {},
                  onEpisodes: episodic ? () {} : null,
                  episode: episodic,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byTooltip('选集'),
            episodic ? findsOneWidget : findsNothing,
          );
          expect(find.byTooltip('字幕').hitTestable(), findsOneWidget);
          expect(find.byTooltip('播放器菜单').hitTestable(), findsOneWidget);
          if (episodic) {
            expect(find.byTooltip('选集').hitTestable(), findsOneWidget);
            expect(
              tester.getCenter(find.byTooltip('字幕')).dy,
              tester.getCenter(find.byTooltip('选集')).dy,
            );
          }
          expect(tester.takeException(), null);
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final spec in {
    'phone-portrait': const Size(412, 915),
    'tablet-portrait': const Size(900, 1280),
    'tablet-landscape': const Size(1280, 800),
    'small-phone': const Size(320, 568),
    'phone-landscape': const Size(844, 390),
  }.entries) {
    for (final mode in [Brightness.dark, Brightness.light]) {
      testWidgets(
        'compact five-column picker opens on episode 50 ${spec.key} ${mode.name}',
        (tester) async {
          tester.view.physicalSize = spec.value;
          tester.view.display.size = spec.value;
          addTearDown(tester.view.display.resetSize);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final calls = <String>[], api = catalogueApi(calls: calls);
          final data = EpisodeMenuData(api), capture = GlobalKey();
          await launch(
            tester,
            data,
            episode(50),
            brightness: mode,
            capture: capture,
            textScale: spec.key == 'small-phone' ? 1.3 : 1,
          );
          final current = find.byKey(const ValueKey('player-episode-s2-e50'));
          expect(current.hitTestable(), findsOneWidget);
          final panel = tester.getRect(
            find.byKey(const Key('player-episode-panel')),
          );
          expect(panel.width, lessThanOrEqualTo(336));
          expect(panel.height, lessThanOrEqualTo(440));
          final square = tester.getSize(current);
          expect(square.width, closeTo(square.height, .01));
          expect(panel.height, greaterThan(panel.width));
          expect(panel.contains(tester.getCenter(current)), true);
          final grid = tester.widget<GridView>(
            find.byKey(const Key('player-episode-grid')),
          );
          expect(
            (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
                .crossAxisCount,
            5,
          );
          expect(
            (grid.childrenDelegate as SliverChildBuilderDelegate).childCount,
            50,
          );
          expect(find.text('1–50'), findsOneWidget);
          expect(find.byKey(const Key('player-episode-season')), findsNothing);
          expect(find.byType(RawScrollbar), findsOneWidget);
          final marked = find.ancestor(
            of: current,
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.selected == true,
            ),
          );
          expect(marked, findsOneWidget);
          expect(calls.length, 1);
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/$appVersion-${spec.key}-player-episodes-${mode.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          // Reopening follows actual playback even after browsing a different range.
          await tester.tap(find.byKey(const Key('player-episode-range')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('101–150'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('关闭选集'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(current.hitTestable(), findsOneWidget);
          expect(
            calls.length,
            1,
            reason: 'Reopening reuses catalogue metadata',
          );
          await tester.pumpWidget(const SizedBox());
          api.close();
          expect(tester.takeException(), null);
        },
      );
    }
  }

  for (final n in [51, 100, 101]) {
    testWidgets(
      'current episode $n selects its range and is visible without scrolling',
      (tester) async {
        final api = catalogueApi();
        await launch(tester, EpisodeMenuData(api), episode(n));
        expect(
          find.byKey(ValueKey('player-episode-s2-e$n')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text(n <= 100 ? '51–100' : '101–150'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        api.close();
      },
    );
  }

  testWidgets(
    'cached detail catalogue works while optional browsing stays suspended',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final calls = <String>[], api = catalogueApi(calls: calls, count: 200);
      final browse = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
      );
      await browse.cache.put(
        browse.key('seasons:series'),
        ItemPage(seasons, 3),
        DateTime.now(),
      );
      final items = List.generate(150, (i) => episode(i + 1));
      await browse.cache.put(
        browse.key(BrowseRepository.episodeCatalogueKey('series', 's2')),
        ItemPage(items, items.length),
        DateTime.now(),
      );
      browse.suspend();
      final data = EpisodeMenuData(api, browse: browse);
      await launch(tester, data, episode(100));
      expect(
        find.byKey(const ValueKey('player-episode-s2-e100')).hitTestable(),
        findsOneWidget,
      );
      expect(calls, isEmpty);
      expect(browse.paused, true);
      await tester.pumpWidget(const SizedBox());
      await launch(tester, data, episode(151));
      expect(
        find.byKey(const ValueKey('player-episode-s2-e151')).hitTestable(),
        findsOneWidget,
      );
      expect(find.text('151–200'), findsOneWidget);
      expect(calls.length, 1);
      expect(calls.single, endsWith('/Shows/series/Episodes'));
      expect(browse.paused, true);
      await tester.pumpWidget(const SizedBox());
      browse.dispose();
      api.close();
    },
  );

  testWidgets(
    'errors retry and dismissed picker responses cannot replace current episodes',
    (tester) async {
      final delayed = Completer<http.Response>();
      var failure = true;
      final api = EmbyClient(
        client: MockClient((r) async {
          final season = r.url.queryParameters['SeasonId']!;
          if (season == 's1') return delayed.future;
          if (season == 's2' && failure) {
            failure = false;
            return response('{}', 503);
          }
          return page(List.generate(50, (i) => episode(i + 1, season)));
        }),
      )..session = syntheticSession();
      final data = EpisodeMenuData(api);
      await launch(tester, data, episode(50));
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('player-episode-s2-e50')).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: EpisodeMenu(current: episode(1, 's1'), data: data),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await launch(tester, data, episode(1, 's3'));
      delayed.complete(page([episode(1, 's1')]));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('player-episode-s3-e1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('player-episode-s1-e1')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      api.close();
      expect(tester.takeException(), null);
    },
  );

  testWidgets('closing picker prevents later catalogue pages and UI updates', (
    tester,
  ) async {
    final delayed = Completer<http.Response>();
    var calls = 0;
    final api = EmbyClient(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/Seasons')) return page(seasons);
        calls++;
        return delayed.future;
      }),
    )..session = syntheticSession();
    await tester.pumpWidget(
      MaterialApp(
        home: EpisodeMenu(current: episode(1), data: EpisodeMenuData(api)),
      ),
    );
    await tester.pump();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    delayed.complete(page([episode(1)], total: 150));
    await tester.pump(const Duration(seconds: 1));
    expect(calls, 1);
    expect(tester.takeException(), null);
    api.close();
  });

  testWidgets(
    'empty catalogue and missing parent metadata show honest states',
    (tester) async {
      for (final missing in [true, false]) {
        final item = missing
            ? MediaItem(Map.of(episode(1).data)..remove('SeasonId'))
            : episode(1);
        final api = EmbyClient(
          client: MockClient(
            (r) async => r.url.path.contains('/Items/')
                ? response(jsonEncode(item.data), 200)
                : page([]),
          ),
        )..session = syntheticSession();
        await launch(tester, EpisodeMenuData(api), item);
        expect(
          find.text(missing ? '无法确认当前分集列表，请重试' : '暂无可播放分集'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox());
        api.close();
      }
    },
  );

  testWidgets(
    'episode picker sits after subtitles, avoids reopening current, then saves before manual switch',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        Device.channel,
        (call) async => call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(Device.channel, null),
      );
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final progress = <String, int>{
        's2-e60': ticks(const Duration(seconds: 120)),
      };
      final events = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          final path = r.url.path;
          if (path.endsWith('/Seasons')) return page(seasons);
          if (path.endsWith('/Episodes')) {
            return page(List.generate(100, (i) => episode(i + 1)));
          }
          if (path.endsWith('PlaybackInfo')) {
            events.add(
              'prepare:${path.split('/')[path.split('/').length - 2]}',
            );
            return response(jsonEncode(playbackData()), 200);
          }
          if (path.contains('Sessions/Playing')) {
            if (path.endsWith('/Stopped')) {
              final body = jsonDecode(r.body) as Map;
              progress[body['ItemId']] = body['PositionTicks'];
              events.add('stopped:${body['ItemId']}');
            }
            return response('', 204);
          }
          final id = path.split('/').last;
          return response(
            jsonEncode({
              ...episode(int.parse(id.split('-e').last)).data,
              'UserData': {'PlaybackPositionTicks': progress[id] ?? 0},
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final sessions = <PlaybackSession>[], backends = <FakeBackend>[];
      PlaybackSession create(MediaItem item) {
        final backend = FakeBackend()..gate.complete();
        backends.add(backend);
        final session = PlaybackSession(
          api: api,
          store: store,
          item: item,
          backend: backend,
        );
        sessions.add(session);
        return session;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            createSession: () => create(episode(50)),
            createSessionForItem: create,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byTooltip('选集')).dx,
        greaterThan(tester.getCenter(find.byTooltip('字幕')).dx),
      );
      await backends.first.seek(const Duration(seconds: 72));
      await tester.pumpAndSettle();
      final episodeAnchor = tester.getRect(find.byTooltip('选集'));
      await tester.tap(find.byTooltip('选集'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const Key('player-episode-panel'))).bottom,
        closeTo(episodeAnchor.top - 4, .01),
      );
      await tester.tap(find.byKey(const ValueKey('player-episode-s2-e50')));
      await tester.pumpAndSettle();
      expect(sessions.length, 1);
      expect(events.where((e) => e.startsWith('stopped:')), isEmpty);
      await tester.tap(find.byTooltip('选集'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('player-episode-range')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('51–100'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('player-episode-s2-e60')));
      for (var i = 0; i < 25 && sessions.length < 2; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
      }
      expect(sessions.length, 2);
      expect(sessions.last.item.id, 's2-e60');
      expect(backends.first.disposed, true);
      expect(progress['s2-e50'], ticks(const Duration(seconds: 72)));
      expect(
        events.indexOf('stopped:s2-e50'),
        lessThan(events.indexOf('prepare:s2-e60')),
      );
      expect(backends.last.initial, const Duration(seconds: 120));
      await tester.tap(find.byTooltip('选集'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('player-episode-s2-e60')).hitTestable(),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-episode-panel')), findsNothing);
      expect(sessions.last.closed, false);
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 25 && !backends.last.disposed; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      expect(tester.takeException(), null);
    },
  );
}
