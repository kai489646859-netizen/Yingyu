import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/swipe_pages.dart';
import 'core_test.dart' show syntheticSession, response;
import 'offline_settle.dart';
import 'offline_capture.dart';
import 'scroll_affordance_test.dart' show fonts;
import 'poster_test.dart' show RecordingCache;

void main() {
  setUp(() {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final old = posterCache, art = artworkCache;
    posterCache = RecordingCache();
    artworkCache = RecordingCache();
    addTearDown(() {
      posterCache = old;
      artworkCache = art;
    });
  });
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    for (final count in [1, 16]) {
      testWidgets(
        'carousel owns short/long rows and page changes retain scroll positions: $size $count',
        (tester) async {
          await fonts();
          final boundary = GlobalKey();
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final store = AppStore(await SharedPreferences.getInstance());
          await store.saveSession(syntheticSession());
          final rows = [
            for (var i = 0; i < 90; i++)
              {
                'Id': 'item-$i',
                'Name': '影片 ${i.toString().padLeft(2, '0')}',
                'Type': 'Movie',
                'ProductionYear': 2000,
                'UserData': {'PlaybackPositionTicks': 100000000},
              },
          ];
          final api = EmbyClient(
            client: MockClient((r) async {
              if (r.url.path.endsWith('/Users/synthetic-user')) {
                return response('{"Id":"synthetic-user"}', 200);
              }
              if (r.url.path.endsWith('/Views')) {
                return response(
                  '{"Items":[{"Id":"movies","Name":"电影","Type":"CollectionFolder"}]}',
                  200,
                );
              }
              if (r.url.path.endsWith('/Latest')) {
                return response(jsonEncode(rows.take(count).toList()), 200);
              }
              if (r.url.path.endsWith('/Resume')) {
                return response(
                  jsonEncode({'Items': rows.take(count).toList()}),
                  200,
                );
              }
              return response(
                jsonEncode({'Items': rows, 'TotalRecordCount': rows.length}),
                200,
              );
            }),
          );
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: YingyuApp(
                store: store,
                api: api,
                backendFactory: () => throw StateError('No native playback'),
              ),
            ),
          );
          await settleOffline(tester);
          int current() => tester
              .widget<GlassNavigation>(find.byType(GlassNavigation))
              .index;
          final strips = find.descendant(
            of: find.byType(HomeDashboard),
            matching: find.byWidgetPredicate(
              (w) => w is ListView && w.scrollDirection == Axis.horizontal,
            ),
          );
          expect(strips, findsNWidgets(2));
          final positions = <ScrollPosition>[];
          for (var i = 0; i < 2; i++) {
            final strip = strips.at(i);
            final scrolling = tester.state<ScrollableState>(
              find.descendant(of: strip, matching: find.byType(Scrollable)),
            );
            positions.add(scrolling.position);
            await tester.drag(strip, const Offset(-260, 0));
            await tester.pumpAndSettle();
            expect(current(), 0);
            expect(scrolling.position.pixels, count == 1 ? 0 : greaterThan(0));
          }
          final homeOffsets = positions.map((p) => p.pixels).toList();
          // The page follows the finger before release; the tab changes at snap.
          final drag = await tester.startGesture(Offset(size.width * .8, 30));
          await drag.moveBy(Offset(-size.width * .35, 0));
          await tester.pump(const Duration(milliseconds: 16));
          final pager = tester.widget<PageView>(
            find.byKey(const Key('main-swipe-pages')),
          );
          expect(pager.controller!.page, allOf(greaterThan(0), lessThan(1)));
          expect(current(), 0);
          if (count == 16) {
            await captureOffline(
              tester,
              boundary,
              'swipe-${size.width.round()}',
            );
          }
          await drag.moveBy(Offset(-size.width * .35, 0));
          await drag.up();
          await settleOffline(tester);
          expect(current(), 1);
          final libraryScroll = tester
              .widget<CustomScrollView>(
                find.descendant(
                  of: find.byType(LibraryPage),
                  matching: find.byType(CustomScrollView),
                ),
              )
              .controller!;
          libraryScroll.jumpTo(600);
          await tester.pumpAndSettle();
          final libraryOffset = libraryScroll.offset;
          // Pinyin scrubbing never turns into a page swipe.
          await tester.dragFrom(
            tester.getCenter(find.byKey(const Key('alphabet-hit-area'))),
            const Offset(-150, 0),
          );
          await tester.pumpAndSettle();
          expect(current(), 1);
          libraryScroll.jumpTo(libraryOffset);
          await tester.pumpAndSettle();
          for (final next in [2, 3]) {
            await tester.dragFrom(
              Offset(size.width * .8, 30),
              Offset(-size.width * .7, 0),
            );
            await settleOffline(tester);
            expect(current(), next);
          }
          for (final previous in [2, 1, 0]) {
            await tester.tap(find.byKey(ValueKey('navigation-tab-$previous')));
            await settleOffline(tester);
            expect(current(), previous);
            if (previous == 1) expect(libraryScroll.offset, libraryOffset);
          }
          expect(positions.map((p) => p.pixels).toList(), homeOffsets);
          // First-page overscroll and a short cancelled drag leave the page alone.
          await tester.dragFrom(
            Offset(size.width * .25, 30),
            const Offset(120, 0),
          );
          await tester.pumpAndSettle();
          expect(current(), 0);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(current(), 0);
          await tester.pumpWidget(const SizedBox());
          api.close();
          store.dispose();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'four main tabs resume horizontal swiping after a background layout rebuild',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      await store.saveSession(syntheticSession());
      final api = EmbyClient(
        client: MockClient(
          (request) async => response(
            request.url.path.endsWith('/Users/synthetic-user')
                ? '{"Id":"synthetic-user"}'
                : '{"Items":[]}',
            200,
          ),
        ),
      );
      await tester.pumpWidget(YingyuApp(store: store, api: api));
      await settleOffline(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.view.physicalSize = const Size(420, 915);
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<SwipePages>(find.byType(SwipePages)).enabled,
        isFalse,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settleOffline(tester);
      for (final index in [1, 2, 3, 2, 1, 0]) {
        final current = tester
            .widget<GlassNavigation>(find.byType(GlassNavigation))
            .index;
        final forward = index > current;
        await tester.dragFrom(
          Offset(forward ? 360 : 60, 30),
          Offset(forward ? -300 : 300, 0),
        );
        await settleOffline(tester);
        expect(
          tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
          index,
          reason: 'Resuming must rebuild the page swipe enabled state',
        );
      }
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.log.dispose();
      store.dispose();
    },
  );

  testWidgets(
    'rapid button changes animate without committing intermediate pages',
    (tester) async {
      final selected = ValueNotifier(0);
      final swipes = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: selected,
            builder: (_, index, _) => SwipePages(
              index: index,
              onChanged: (next) {
                swipes.add(next);
                selected.value = next;
              },
              children: [
                for (var i = 0; i < 4; i++)
                  ColoredBox(color: Colors.blue, child: Text('page $i')),
              ],
            ),
          ),
        ),
      );
      selected.value = 3;
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      expect(controller.page, allOf(greaterThan(0), lessThan(3)));
      selected.value = 1;
      await tester.pump();
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      expect(swipes, isEmpty);
      selected.value = 2;
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      selected.dispose();
    },
  );

  testWidgets(
    'appearance order is system light dark, and system follows device brightness',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.saveSession(syntheticSession());
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            r.url.path.endsWith('/Users/synthetic-user')
                ? '{"Id":"synthetic-user"}'
                : '{"Items":[]}',
            200,
          ),
        ),
      );
      await tester.pumpWidget(YingyuApp(store: store, api: api));
      await settleOffline(tester);
      await tester.tap(find.byKey(const ValueKey('navigation-tab-2')));
      await settleOffline(tester);
      final picker = tester.widget<CupertinoSlidingSegmentedControl<ThemeMode>>(
        find.byType(CupertinoSlidingSegmentedControl<ThemeMode>),
      );
      expect(picker.children.keys.toList(), [
        ThemeMode.system,
        ThemeMode.light,
        ThemeMode.dark,
      ]);
      expect(picker.groupValue, ThemeMode.system);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.pumpAndSettle();
      expect(
        Theme.of(
          tester.element(find.byKey(const Key('phone-navigation'))),
        ).brightness,
        Brightness.dark,
      );
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(
        Theme.of(
          tester.element(find.byKey(const Key('phone-navigation'))),
        ).brightness,
        Brightness.light,
      );
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    },
  );
}
