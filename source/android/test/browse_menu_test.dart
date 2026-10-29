import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, syntheticSession;
import 'offline_settle.dart';

void main() {
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    for (final kind in ['sort', 'library']) {
      testWidgets(
        '$kind stays open while outside drag and wheel scroll the wall at $size',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          var calls = 0, opened = 0;
          final api = EmbyClient(
            client: MockClient((request) async {
              if (request.url.path.endsWith('/Views')) {
                return response(
                  '{"Items":[{"Id":"movies","Name":"电影"},{"Id":"anime","Name":"动漫"}]}',
                  200,
                );
              }
              calls++;
              return response(
                jsonEncode({
                  'Items': [
                    for (var i = 0; i < 90; i++)
                      {'Id': 'movie-$i', 'Name': '合成影片 $i', 'Type': 'Movie'},
                  ],
                  'TotalRecordCount': 90,
                }),
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
          final active = ValueNotifier(true);
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(Brightness.light),
              home: Scaffold(
                body: ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (_, enabled, _) => LibraryPage(
                    active: enabled,
                    api: api,
                    browse: repo,
                    onItem: (_) async => opened++,
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          final originalCalls = calls;
          final wall = tester.widget<CustomScrollView>(
            find.byType(CustomScrollView),
          );
          final controller = wall.controller!;
          final button = find.byKey(
            Key(kind == 'sort' ? 'library-sort' : 'library-picker'),
          );
          await tester.tap(button);
          await settleOffline(tester);
          final panelFinder = find.byKey(const Key('browse-menu-panel'));
          final panel = tester.getRect(panelFinder);
          final wallRect = tester.getRect(find.byType(CustomScrollView));
          final x = kind == 'sort' ? 36.0 : size.width - 64;
          final point = Offset(x, wallRect.bottom - 50);
          expect(panel.contains(point), false);
          await tester.dragFrom(point, const Offset(0, -190));
          await settleOffline(tester);
          expect(controller.offset, greaterThan(100));
          expect(panelFinder, findsOneWidget);
          expect(opened, 0);
          final beforeWheel = controller.offset;
          await tester.sendEventToBinding(
            PointerScrollEvent(
              position: point,
              scrollDelta: const Offset(0, 80),
            ),
          );
          await settleOffline(tester);
          expect(controller.offset, greaterThan(beforeWheel));
          expect(panelFinder, findsOneWidget);
          final beforeTap = controller.offset;
          await tester.tapAt(point);
          await settleOffline(tester);
          expect(panelFinder, findsNothing);
          expect(controller.offset, closeTo(beforeTap, .1));
          expect(
            opened,
            0,
            reason: 'The dismissal tap must not open a poster underneath',
          );
          await tester.tap(button);
          await settleOffline(tester);
          await tester.binding.handlePopRoute();
          await settleOffline(tester);
          expect(panelFinder, findsNothing);
          expect(controller.offset, closeTo(beforeTap, .1));
          expect(find.byType(LibraryPage), findsOneWidget);
          // Deactivating the page removes both its menu and its local back entry.
          await tester.tap(button);
          await settleOffline(tester);
          active.value = false;
          await settleOffline(tester);
          expect(panelFinder, findsNothing);
          active.value = true;
          await settleOffline(tester);
          await tester.tap(button);
          await settleOffline(tester);
          tester.view.physicalSize = Size(size.height, size.width);
          await settleOffline(tester);
          expect(panelFinder, findsNothing);
          expect(calls, originalCalls);
          await tester.tap(button);
          await settleOffline(tester);
          await tester.pumpWidget(const SizedBox());
          active.dispose();
          repo.dispose();
          api.close();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'short-screen large-text menu scrolls internally without moving the wall',
    (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final api = EmbyClient(
        client: MockClient(
          (request) async => response(
            request.url.path.endsWith('/Views')
                ? '{"Items":[]}'
                : '{"Items":[{"Id":"one","Name":"合成影片","Type":"Movie"}],"TotalRecordCount":1}',
            200,
          ),
        ),
      )..session = syntheticSession();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(
              size: Size(640, 360),
              textScaler: TextScaler.linear(1.7),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: LibraryPage(api: api, onItem: (_) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      final wall = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      await tester.tap(find.byKey(const Key('library-sort')));
      await settleOffline(tester);
      final panel = find.byKey(const Key('browse-menu-panel'));
      expect(tester.getRect(panel).bottom, lessThanOrEqualTo(360));
      final inner = find.descendant(
        of: panel,
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('played:true')),
        120,
        scrollable: inner,
      );
      expect(wall.offset, 0);
      await tester.tap(find.byKey(const ValueKey('played:true')));
      await settleOffline(tester);
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );
}
