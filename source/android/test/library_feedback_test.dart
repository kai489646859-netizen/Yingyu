import 'package:yingyu/ui/release_refresh.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/library_layout.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, syntheticSession;
import 'offline_settle.dart';
import 'offline_capture.dart';
import 'scroll_affordance_test.dart' show fonts;

void main() {
  setUp(syntheticImagePaths);
  test(
    'new appearance defaults to system and explicit theme choices survive',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      expect(store.theme, ThemeMode.system);
      for (final theme in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
        await store.setTheme(theme);
        final reopened = AppStore(prefs);
        expect(reopened.theme, theme);
        reopened.dispose();
      }
      store.dispose();
    },
  );

  for (final display in LibraryDisplay.values) {
    for (final width in [360.0, 1280.0]) {
      testWidgets(
        'loading above rail and fixed wall during every sort: $display $width',
        (tester) async {
          await fonts();
          final boundary = GlobalKey();
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          var stalled = false;
          final release = Completer<void>();
          final rows = [
            for (var i = 0; i < 60; i++)
              {
                'Id': '$i',
                'Name': '影片 ${i.toString().padLeft(2, '0')}',
                'Type': 'Movie',
                'ProductionYear': 2000,
                'CommunityRating': 8,
                'DateCreated': '2026-01-01',
                '_YingyuSortMetadataV1': true,
              },
          ];
          final api = EmbyClient(
            client: MockClient((request) async {
              if (request.url.path.endsWith('/Views')) {
                return response('{"Items":[]}', 200);
              }
              if (stalled) await release.future;
              return response(
                jsonEncode({'Items': rows, 'TotalRecordCount': rows.length}),
                200,
              );
            }),
          )..session = syntheticSession();
          final repo = BrowseRepository(
            api,
            BrowseCache(prefs),
            BrowsePreferences(prefs),
            spacing: Duration.zero,
          );
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(Brightness.light),
                home: Scaffold(
                  resizeToAvoidBottomInset: false,
                  body: LibraryPage(
                    api: api,
                    browse: repo,
                    display: display,
                    onItem: (_) async {},
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          final cards = display == LibraryDisplay.standard
              ? find.byType(MediaCard)
              : find.byType(LibraryPosterCard);
          final columnCount =
              (tester
                          .widget<SliverGrid>(
                            find.byWidgetPredicate(
                              (widget) => widget is SliverGrid,
                            ),
                          )
                          .gridDelegate
                      as SliverGridDelegateWithFixedCrossAxisCount)
                  .crossAxisCount;
          List<Rect> rects() => [
            for (var i = 0; i < columnCount; i++) tester.getRect(cards.at(i)),
          ];
          final before = rects();
          final railX = tester
              .getCenter(find.byKey(const Key('alphabet-hit-area')))
              .dx;
          stalled = true;
          final refreshing = tester
              .widget<ReleaseRefreshScrollView>(
                find.byType(ReleaseRefreshScrollView, skipOffstage: false),
              )
              .onRefresh();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          final loading = find.byKey(const Key('library-loading-indicator'));
          expect(loading, findsOneWidget);
          expect(tester.getCenter(loading).dx, closeTo(railX, .1));
          expect(rects(), before);
          await captureOffline(
            tester,
            boundary,
            'loading-${display.name}-${width.round()}',
          );
          for (final sort in [
            'DateCreated',
            'PremiereDate',
            'CommunityRating',
            'alphabet',
          ]) {
            await tester.tap(find.byKey(const Key('library-sort')));
            await tester.pump(const Duration(milliseconds: 250));
            await tester.tap(find.byKey(ValueKey('sort:$sort')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
            expect(
              loading,
              findsOneWidget,
              reason: 'Metadata loading is independent of the selected sort',
            );
            expect(tester.getCenter(loading).dx, closeTo(railX, .1));
            expect(
              rects(),
              before,
              reason:
                  'Changing the rail or loading state must not move the wall',
            );
            expect(
              find.byKey(const Key('alphabet-hit-area')),
              sort == 'alphabet' ? findsOneWidget : findsNothing,
            );
          }
          release.complete();
          await refreshing;
          await settleOffline(tester);
          expect(loading, findsNothing);
          expect(rects(), before);
          await tester.pumpWidget(const SizedBox());
          repo.dispose();
          api.close();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'sort stays usable as keyboard height changes and can reopen repeatedly',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final api = EmbyClient(
        client: MockClient(
          (r) async => response(
            r.url.path.endsWith('/Views')
                ? '{"Items":[]}'
                : '{"Items":[{"Id":"a","Name":"影片","Type":"Movie"}],"TotalRecordCount":1}',
            200,
          ),
        ),
      )..session = syntheticSession();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: LibraryPage(api: api, onItem: (_) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      await tester.tap(find.byKey(const Key('library-search')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('library-sort'));
      await tester.tap(button);
      await tester.pumpAndSettle();
      for (final height in [270.0, 160.0, 0.0, 200.0, 320.0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        await tester.pumpAndSettle();
        final menu = find.byKey(const Key('browse-menu-panel'));
        expect(menu, findsOneWidget);
        expect(tester.getRect(menu).bottom, lessThanOrEqualTo(915 - height));
      }
      await tester.tap(find.byKey(const ValueKey('sort:DateCreated')));
      await settleOffline(tester);
      for (var i = 0; i < 4; i++) {
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('browse-menu-panel')), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('browse-menu-panel')), findsNothing);
      }
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );
}
