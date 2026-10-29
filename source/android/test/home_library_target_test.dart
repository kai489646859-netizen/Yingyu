import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'poster_test.dart' show RecordingCache;
import 'offline_settle.dart';

void main() {
  testWidgets(
    'home anime view-all selects the main library; switching partition updates heading and reuses all',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      syntheticImagePaths();
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final old = posterCache, oldArt = artworkCache;
      posterCache = RecordingCache();
      artworkCache = RecordingCache();
      addTearDown(() {
        posterCache = old;
        artworkCache = oldArt;
      });
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final catalogCalls = <String>[];
      const libraries = [
        {
          'Id': 'anime',
          'Name': '动漫',
          'Type': 'CollectionFolder',
          'IsFolder': true,
        },
        {
          'Id': 'series',
          'Name': '剧集',
          'Type': 'CollectionFolder',
          'IsFolder': true,
        },
      ];
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Users/synthetic-user')) {
            return response('{"Id":"synthetic-user"}', 200);
          }
          final path = request.url.path,
              parent = request.url.queryParameters['ParentId'] ?? 'all';
          if (path.endsWith('/Views')) {
            return response(jsonEncode({'Items': libraries}), 200);
          }
          if (path.contains('/Resume')) return response('{"Items":[]}', 200);
          final rows = [
            {
              'Id': '$parent-title',
              'Name': parent == 'anime' ? '动漫内容' : '剧集内容',
              'Type': 'Series',
            },
          ];
          if (path.endsWith('/Latest')) return response(jsonEncode(rows), 200);
          if (path.endsWith('/Items')) catalogCalls.add(parent);
          return response(
            jsonEncode({'Items': rows, 'TotalRecordCount': 1}),
            200,
          );
        }),
      )..session = syntheticSession();
      await store.saveSession(api.session!);
      await tester.pumpWidget(YingyuApp(store: store, api: api));
      await settleOffline(tester);
      Future<void> tab(String title) async {
        await tester.tap(find.text(title).hitTestable().last);
        await settleOffline(tester);
      }

      await tab('媒体库');
      await settleOffline(tester);
      expect(catalogCalls, ['anime', 'series']);
      await tab('首页');
      final row = find
          .ancestor(of: find.text('最新动漫'), matching: find.byType(Row))
          .first;
      await tester.tap(find.descendant(of: row, matching: find.text('查看全部')));
      await settleOffline(tester);
      expect(
        tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
        1,
      );
      expect(find.byType(LibraryPage), findsOneWidget);
      expect(find.widgetWithText(SectionHeading, '媒体库'), findsOneWidget);
      final heading = find.byType(SectionHeading);
      expect(
        find.descendant(of: heading, matching: find.text('动漫')),
        findsOneWidget,
      );
      expect(find.text('动漫内容').hitTestable(), findsOneWidget);
      expect(find.text('剧集内容').hitTestable(), findsNothing);
      final picker = find.byKey(const Key('library-picker'));
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('剧集').hitTestable().last);
      await settleOffline(tester);
      expect(
        find.descendant(of: heading, matching: find.text('剧集')),
        findsOneWidget,
      );
      expect(find.text('剧集内容').hitTestable(), findsOneWidget);
      expect(find.text('动漫内容').hitTestable(), findsNothing);
      expect(catalogCalls, ['anime', 'series']);
      await tester.tap(find.byKey(const ValueKey('navigation-tab-0')));
      await settleOffline(tester);
      expect(
        tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
        0,
      );
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
