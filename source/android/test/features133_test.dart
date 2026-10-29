import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'player_episode_menu_test.dart' show fonts;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/people.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/core/store.dart';
import 'package:flutter/cupertino.dart';
import 'core_test.dart' show syntheticSession;
import 'offline_settle.dart' show syntheticImagePaths;

Future<void> savePreview(WidgetTester tester, GlobalKey capture, String name) =>
    tester.runAsync(() async {
      final image =
          await (capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/ui-previews/1.3.3-settings-$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });

final castDetail = MediaItem({
  'Id': 'series',
  'Type': 'Series',
  'Name': 'Synthetic series',
  'People': [
    {
      'Id': 'actor',
      'Name': 'Synthetic actor',
      'Role': 'Lead',
      'PrimaryImageTag': 'portrait',
      'Path': 'never persist',
    },
  ],
});

class CastApi extends EmbyClient {
  CastApi() {
    session = syntheticSession();
  }
  final seasonsGate = Completer<ItemPage>();
  final historyGate = Completer<MediaItem?>();
  int detailCalls = 0;
  @override
  Future<MediaItem> detail(String id, {Duration? requestTimeout}) async {
    detailCalls++;
    return castDetail;
  }

  @override
  Future<ItemPage> seasons(String id) => seasonsGate.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    SharedPreferences.setMockInitialValues({});
  });
  test(
    'cast display fields survive cache serialization without private fields',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final cache = BrowseCache(prefs);
      await cache.put(
        'detail:series',
        ItemPage([castDetail], 1),
        DateTime.now(),
      );
      final restored = BrowseCache(
        prefs,
      ).records['detail:series']!.items.single;
      expect(
        objects(restored.data['People']).single['Name'],
        'Synthetic actor',
      );
      expect(
        objects(restored.data['People']).single.containsKey('Path'),
        false,
      );
    },
  );
  test(
    'legacy sparse detail is refreshed once on opening, then persisted cast is reused',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final api = CastApi();
      final browse = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      addTearDown(() {
        browse.dispose();
        api.close();
      });
      await browse.cache.put(
        browse.key('detail:series'),
        ItemPage([
          MediaItem({'Id': 'series', 'Type': 'Series'}),
        ], 1),
        DateTime.now(),
      );
      expect(
        objects((await browse.detail('series')).data['People']),
        isNotEmpty,
      );
      expect(
        objects((await browse.detail('series')).data['People']),
        isNotEmpty,
      );
      expect(api.detailCalls, 1);
      final reloaded = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      addTearDown(reloaded.dispose);
      expect(
        objects((await reloaded.detail('series')).data['People']),
        isNotEmpty,
      );
      expect(api.detailCalls, 1);
    },
  );
  testWidgets(
    'next preparation is a default-on switch in playback; all new rows have icons',
    (tester) async {
      await fonts();
      tester.view.physicalSize = const Size(412, 915);
      tester.view.display.size = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.display.resetSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final capture = GlobalKey();
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs), api = CastApi();
      final browse = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
      );
      addTearDown(() {
        browse.dispose();
        api.close();
        store.log.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(
            body: RepaintBoundary(
              key: capture,
              child: ColoredBox(
                color: const Color(0xFFF1EFF6),
                child: SettingsPage(store: store, browse: browse),
              ),
            ),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('prepare-next')),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      final row = tester.widget<SettingsRow>(
        find.byKey(const Key('prepare-next')),
      );
      expect(row.icon, isNotNull);
      expect(row.trailing, isA<CupertinoSwitch>());
      expect((row.trailing as CupertinoSwitch).value, true);
      final groups = tester.widgetList<SettingsGroup>(
        find.ancestor(
          of: find.byKey(const Key('prepare-next')),
          matching: find.byType(SettingsGroup),
        ),
      );
      expect(groups.single.title, '播放');
      await tester.ensureVisible(find.text('下一集准备'));
      await tester.pumpAndSettle();
      await savePreview(tester, capture, 'playback');
      (row.trailing as CupertinoSwitch).onChanged!(false);
      await tester.pumpAndSettle();
      expect(prefs.getBool('yingyu.next.prepare.v1'), false);
      expect(find.text('防剧透'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('演员图片缓存'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      for (final title in ['演员图片缓存上限', '演员图片缓存']) {
        expect(
          find.descendant(
            of: find
                .ancestor(
                  of: find.text(title),
                  matching: find.byType(SettingsGroup),
                )
                .first,
            matching: find.byType(SettingsIcon),
          ),
          findsWidgets,
        );
      }
      await tester.ensureVisible(find.text('演员图片缓存'));
      await tester.pumpAndSettle();
      await savePreview(tester, capture, 'cache');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'cast renders as soon as detail arrives while seasons and history are pending',
    (tester) async {
      final api = CastApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: MediaItem({'Id': 'series', 'Type': 'Series'}),
            api: api,
            watchedEpisode: (_) => api.historyGate.future,
            play: (_, _, _) async {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.byType(PeopleRail), findsOneWidget);
      api.seasonsGate.complete(ItemPage([], 0));
      api.historyGate.complete(null);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'serial browse queue publishes cast before a pending seasons request',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final api = CastApi();
      final browse = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      addTearDown(() {
        browse.dispose();
        api.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: MediaItem({'Id': 'series', 'Type': 'Series'}),
            api: api,
            browse: browse,
            watchedEpisode: (_) => api.historyGate.future,
            play: (_, _, _) async {},
          ),
        ),
      );
      for (var n = 0; n < 10; n++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(PeopleRail), findsOneWidget);
      api.seasonsGate.complete(ItemPage([], 0));
      api.historyGate.complete(null);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
