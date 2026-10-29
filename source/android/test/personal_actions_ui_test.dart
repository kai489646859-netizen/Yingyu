import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_sync.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/account_avatar.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/home_order.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/library_layout.dart';
import 'package:yingyu/ui/poster_actions.dart';
import 'package:yingyu/ui/personal_status_page.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession;
import 'cache_settings_test.dart' show fonts;
import 'offline_settle.dart' show settleOffline;
import 'personal_sync_test.dart' show PersonalServer, personalMovie;

void main() {
  late AppStore store;
  late EmbyClient api;
  late PersonalSync sync;
  late HomeFeed feed;
  late InterfacePreferences preferences;
  late PersonalServer server;
  var opens = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    store = AppStore(await SharedPreferences.getInstance());
    server = PersonalServer();
    api = EmbyClient(client: MockClient(server.call))
      ..session = syntheticSession();
    sync = PersonalSync(api, store.personal);
    feed = HomeFeed(api, store);
    preferences = InterfacePreferences(store.prefs);
    await preferences.setPosterActionMode(PosterActionMode.longPress);
    opens = 0;
  });
  tearDown(() async {
    feed.dispose();
    sync.dispose();
    preferences.dispose();
    api.close();
    // The home now emits a refresh summary inside the widget's FakeAsync
    // clock. Close its timer here without waiting on that retired clock;
    // persistence/flush ordering has separate real-async journal coverage.
    store.log.dispose();
    store.dispose();
  });
  Widget scope(Widget child) => PosterActionsScope(
    sync: sync,
    preferences: preferences,
    feed: feed,
    onItem: (_) async {
      opens++;
    },
    child: child,
  );
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: scope(Center(child: child))),
      ),
    );
    await settleOffline(tester);
  }

  Widget cover(MediaItem item, {bool resume = false}) => SizedBox(
    width: 120,
    height: 180,
    child: GestureDetector(
      onTap: () {
        opens++;
      },
      child: PosterActionRegion(
        item: item,
        resume: resume,
        child: const ColoredBox(key: Key('cover'), color: Colors.blue),
      ),
    ),
  );

  testWidgets(
    'menu is default and explicit long press leaves taps and scroll gestures intact',
    (tester) async {
      final item = personalMovie('a');
      server.entries['a'] = item;
      await store.prefs.remove('yingyu.ui.posterActions.v1');
      expect(preferences.posterActionMode, PosterActionMode.menu);
      await preferences.setPosterActionMode(PosterActionMode.longPress);
      await mount(tester, cover(item));
      await tester.tap(find.byKey(const Key('cover')));
      expect(opens, 1);
      await tester.drag(find.byKey(const Key('cover')), const Offset(0, -50));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('poster-action-favorite-a')), findsNothing);
      await tester.longPress(find.byKey(const Key('cover')));
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(find.byKey(const Key('poster-action-hide-a')), findsNothing);
      expect(find.byKey(const Key('poster-action-played-a')), findsOneWidget);
      await tester.tap(find.byKey(const Key('poster-action-favorite-a')));
      await settleOffline(tester);
      expect(sync.favorite(item), true);
      expect(sync.busy, false);
      await preferences.setPosterActionMode(PosterActionMode.menu);
      await tester.pumpAndSettle();
      expect(
        InterfacePreferences(store.prefs).posterActionMode,
        PosterActionMode.menu,
      );
      await tester.longPress(find.byKey(const Key('cover')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('poster-action-favorite-a')), findsNothing);
      final button = tester.getRect(find.byKey(const Key('poster-more-a'))),
          bounds = tester.getRect(find.byKey(const Key('cover')));
      expect(button.width, 44);
      expect(button.right, bounds.right);
      expect(button.bottom, bounds.bottom - 4);
      await tester.tap(find.byKey(const Key('poster-more-a')));
      await tester.pumpAndSettle();
      expect(find.text('取消收藏'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final type in [
    'Movie',
    'Episode',
    'Series',
    'Season',
    'CollectionFolder',
  ]) {
    testWidgets(
      'poster actions match $type and only continue watching offers hide',
      (tester) async {
        final item = MediaItem({...personalMovie('a').data, 'Type': type});
        await mount(tester, cover(item, resume: type == 'Episode'));
        await tester.longPress(find.byKey(const Key('cover')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('poster-action-played-a')),
          ['Movie', 'Episode'].contains(type) ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('poster-action-favorite-a')),
          type == 'CollectionFolder' ? findsNothing : findsOneWidget,
        );
        expect(
          find.byKey(const Key('poster-action-hide-a')),
          type == 'Episode' ? findsOneWidget : findsNothing,
        );
        final menu = tester.getRect(
          find.byWidgetPredicate((widget) => widget is PopupMenuItem).first,
        );
        expect(menu.width, lessThan(type == 'Episode' ? 190 : 125));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final traditional in [false, true]) {
    testWidgets(
      'actual ${traditional ? 'traditional' : 'standard'} poster has shared long press and original tap',
      (tester) async {
        final item = personalMovie('a');
        await mount(
          tester,
          SizedBox(
            width: traditional ? 140 : 380,
            height: traditional ? 272 : 140,
            child: traditional
                ? LibraryPosterCard(
                    item: item,
                    api: api,
                    active: true,
                    onTap: () {
                      opens++;
                    },
                  )
                : MediaCard(
                    item: item,
                    api: api,
                    onTap: () {
                      opens++;
                    },
                  ),
          ),
        );
        await tester.tapAt(
          tester.getTopLeft(find.byType(PosterActionRegion)) +
              const Offset(20, 20),
        );
        expect(opens, 1);
        await tester.longPressAt(
          tester.getTopLeft(find.byType(PosterActionRegion)) +
              const Offset(20, 20),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('poster-action-favorite-a')),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final width in [320.0, 600.0]) {
    for (final target in ['title', 'overview', 'gap']) {
      testWidgets(
        'text list long press opens one shared menu at $target width $width',
        (tester) async {
          final item = MediaItem({
            ...personalMovie('a').data,
            'Overview': '长按简介也能展开操作',
          });
          await mount(
            tester,
            SizedBox(
              width: width,
              height: 140,
              child: MediaCard(item: item, api: api, onTap: () => opens++),
            ),
          );
          final title = tester.getRect(find.text(item.title));
          final card = tester.getRect(find.byType(MediaCard));
          final position = switch (target) {
            'title' => title.center,
            'overview' => tester.getCenter(find.text(item.overview)),
            _ => Offset(title.left - 5, card.center.dy),
          };
          await tester.tapAt(position);
          expect(opens, 1);
          await tester.longPressAt(position);
          await tester.pumpAndSettle();
          expect(opens, 1, reason: 'A long press must not open details');
          expect(
            find.byKey(const Key('poster-action-favorite-a')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('poster-action-played-a')),
            findsOneWidget,
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets('text list keeps scrolling and disabled long press intact', (
    tester,
  ) async {
    final item = personalMovie('a');
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    Widget card({bool active = true}) => SizedBox(
      width: 380,
      height: 140,
      child: MediaCard(
        item: item,
        api: api,
        active: active,
        onTap: () => opens++,
      ),
    );
    await mount(
      tester,
      SingleChildScrollView(
        controller: scroll,
        child: Column(children: [card(), const SizedBox(height: 1000)]),
      ),
    );
    await tester.drag(find.text(item.title), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(opens, 0);
    expect(find.byKey(const Key('poster-action-favorite-a')), findsNothing);
    await mount(tester, card(active: false));
    await tester.longPress(find.text(item.title));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poster-action-favorite-a')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final target in ['title', 'metadata']) {
    testWidgets(
      'text list $target press uses the existing feedback for every line',
      (tester) async {
        await fonts();
        final capture = GlobalKey();
        final item = MediaItem({
          ...personalMovie('a').data,
          'Name': '合成影片',
          'ProductionYear': 2023,
          'RunTimeTicks': 23 * 60 * 10000000,
          'CommunityRating': 9.1,
          'UserData': <String, dynamic>{},
          'Overview': '',
        });
        await mount(
          tester,
          RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 380,
              height: 140,
              child: MediaCard(item: item, api: api, onTap: () => opens++),
            ),
          ),
        );
        Color? textColor(String text) {
          final rich = tester.widget<RichText>(
            find.descendant(
              of: find.text(text),
              matching: find.byType(RichText),
            ),
          );
          final style = (rich.text as TextSpan).style!;
          return style.foreground?.color ?? style.color;
        }

        final titleIdle = textColor(item.title);
        final metadataIdle = textColor(item.subtitle);
        final pressedAt = find.text(
          target == 'title' ? item.title : item.subtitle,
        );
        final gesture = await tester.startGesture(tester.getCenter(pressedAt));
        await tester.pump();
        final feedback = textColor(item.title);
        expect(feedback, isNot(titleIdle));
        expect(textColor(item.subtitle), feedback);
        expect(textColor(item.rating), feedback);
        expect(textColor('Emby'), feedback);
        expect(find.byKey(const Key('poster-pressed')), findsNothing);
        await tester.runAsync(() async {
          final picture =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await picture.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final directory = Directory('build/ui-previews');
          await directory.create(recursive: true);
          await File(
            '${directory.path}/$appVersion-list-text-$target-pressed.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          picture.dispose();
        });
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(opens, 0);
        expect(
          find.byKey(const Key('poster-action-favorite-a')),
          findsOneWidget,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(textColor(item.title), titleIdle);
        expect(textColor(item.subtitle), metadataIdle);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('text list three-dot mode still uses the title menu', (
    tester,
  ) async {
    final item = personalMovie('a');
    await preferences.setPosterActionMode(PosterActionMode.menu);
    await mount(
      tester,
      SizedBox(
        width: 380,
        height: 140,
        child: MediaCard(item: item, api: api, onTap: () => opens++),
      ),
    );
    await tester.longPress(find.text(item.title));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poster-action-favorite-a')), findsNothing);
    await tester.tap(find.byKey(const Key('poster-more-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('poster-action-favorite-a')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'single action uses aligned 44px trigger and no intermediate menu',
    (tester) async {
      var clicks = 0;
      await mount(
        tester,
        SizedBox(
          width: 340,
          child: SettingsAction(
            id: 'licenses',
            title: '开源许可',
            actionLabel: '查看许可',
            icon: CupertinoIcons.doc_text,
            subtitle: '依赖许可',
            onAction: () {
              clicks++;
            },
          ),
        ),
      );
      await tester.tap(find.text('开源许可'));
      expect(clicks, 1);
      final button = find.byKey(const Key('licenses-arrow'));
      expect(tester.getSize(button), const Size(44, 44));
      expect(
        tester.getCenter(button).dy,
        tester.getCenter(find.text('开源许可')).dy,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(clicks, 2);
      expect(
        find.byWidgetPredicate((widget) => widget is PopupMenuItem),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'server favorites page loads and cancel favorite removes only the selected card',
    (tester) async {
      for (final id in ['a', 'b', 'c']) {
        server.entries[id] = personalMovie(id, favorite: true);
      }
      await preferences.setPosterActionMode(PosterActionMode.menu);
      await mount(
        tester,
        PersonalStatusPage(
          sync: sync,
          list: PersonalList.favorites,
          onItem: (_) async {},
        ),
      );
      await settleOffline(tester);
      expect(find.byType(LibraryPosterCard), findsNWidgets(3));
      await tester.tap(find.byKey(const Key('poster-more-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('poster-action-favorite-a')));
      await settleOffline(tester);
      expect(find.byType(LibraryPosterCard), findsNWidgets(2));
      expect(server.entries['a']!.resume, const Duration(seconds: 60));
      expect(object(server.entries['b']!.data['UserData'])['IsFavorite'], true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'server list denial remains visible and does not pretend to be empty success',
    (tester) async {
      server.failure = 403;
      await mount(
        tester,
        PersonalStatusPage(
          sync: sync,
          list: PersonalList.likes,
          onItem: (_) async {},
        ),
      );
      await settleOffline(tester);
      expect(find.text('重试'), findsOneWidget);
      expect(find.byType(MediaCard), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final display in LibraryDisplay.values) {
    testWidgets(
      'poster watched action updates the active unplayed wall $display',
      (tester) async {
        tester.view.physicalSize = const Size(1000, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        for (final id in ['a', 'b', 'c']) {
          server.entries[id] = MediaItem({
            ...personalMovie(id).data,
            'ProviderIds': {},
          });
        }
        final repo = BrowseRepository(
          api,
          BrowseCache(store.prefs),
          BrowsePreferences(store.prefs),
          spacing: Duration.zero,
        );
        await preferences.setPosterActionMode(PosterActionMode.menu);
        await mount(
          tester,
          LibraryPage(
            api: api,
            browse: repo,
            display: display,
            onItem: (_) async {},
          ),
        );
        await tester.tap(find.byKey(const Key('library-sort')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('played:false')));
        await tester.tap(find.byKey(const ValueKey('played:false')));
        await settleOffline(tester);
        expect(find.byKey(const Key('poster-more-a')), findsOneWidget);
        await tester.tap(find.byKey(const Key('poster-more-a')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('poster-action-played-a')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定'));
        await settleOffline(tester);
        expect(find.byKey(const Key('poster-more-a')), findsNothing);
        expect(find.byKey(const Key('poster-more-b')), findsOneWidget);
        expect(object(server.entries['a']!.data['UserData'])['Played'], true);
        expect(server.requests.where((r) => r.method == 'POST').length, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        repo.dispose();
      },
    );
  }

  for (final brightness in Brightness.values) {
    for (final width in [320.0, 800.0, 1280.0]) {
      testWidgets(
        'home controls precede avatar and remain usable $brightness $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 850);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final capture = GlobalKey();
          var searches = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: Scaffold(
                  body: scope(
                    PageHeaderAction(
                      action: AccountSwitchButton(
                        account: api.session!,
                        display: store.accountDisplays.read(api.session!),
                        onTap: () async {},
                      ),
                      child: HomeDashboard(
                        feed: feed,
                        active: true,
                        onItem: (_) async {},
                        onPlay: (_) async {},
                        onSearch: () {
                          searches++;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          final search = find.byKey(const Key('home-search')),
              sort = find.byKey(const Key('home-order')),
              refresh = find.byKey(const Key('home-refresh')),
              avatar = find.byKey(const Key('quick-account-switch'));
          for (final button in [search, sort, refresh]) {
            expect(tester.getSize(button), const Size(44, 44));
          }
          expect(
            tester.getRect(search).right,
            lessThanOrEqualTo(tester.getRect(sort).left),
          );
          expect(
            tester.getRect(sort).right,
            lessThanOrEqualTo(tester.getRect(refresh).left),
          );
          expect(
            tester.getRect(refresh).right,
            lessThanOrEqualTo(tester.getRect(avatar).left),
          );
          expect(tester.takeException(), isNull);
          await tester.tap(search);
          expect(searches, 1);
          await tester.tap(sort);
          await tester.pumpAndSettle();
          expect(find.byType(HomeOrderPage), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final picture =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/$appVersion-home-controls-${brightness.name}-${width.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: Scaffold(
                  body: scope(
                    Center(
                      child: SizedBox(
                        width: 140,
                        height: 272,
                        child: LibraryPosterCard(
                          item: personalMovie('preview'),
                          api: api,
                          active: true,
                          onTap: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.longPressAt(
            tester.getTopLeft(find.byType(PosterActionRegion)) +
                const Offset(20, 20),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('poster-action-favorite-preview')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final picture =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await picture.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'build/ui-previews/$appVersion-poster-actions-${brightness.name}-${width.toInt()}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            picture.dispose();
          });
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
