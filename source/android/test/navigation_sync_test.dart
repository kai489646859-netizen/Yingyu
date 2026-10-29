import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'offline_settle.dart';
import 'poster_test.dart' show RecordingCache;

void main() {
  late SharedPreferences prefs;
  late EmbyClient api;
  setUp(() async {
    syntheticImagePaths();
    final oldPoster = posterCache, oldArtwork = artworkCache;
    posterCache = RecordingCache();
    artworkCache = RecordingCache();
    addTearDown(() {
      posterCache = oldPoster;
      artworkCache = oldArtwork;
    });
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final all = [
      for (var letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split(''))
        for (var n = 0; n < 6; n++)
          {'Id': '$letter$n', 'Name': '$letter$n', 'Type': 'Movie'},
    ];
    api = EmbyClient(
      client: MockClient((r) async {
        if (r.url.path.endsWith('/Users/synthetic-user')) {
          return response('{"Id":"synthetic-user"}', 200);
        }
        if (r.url.path.endsWith('/Latest')) return response('[]', 200);
        if (r.url.path.endsWith('/Views') || r.url.path.contains('/Resume')) {
          return response('{"Items":[]}', 200);
        }
        if (r.url.path.endsWith('/Items/A0')) {
          return response(jsonEncode(all.first), 200);
        }
        return response(
          jsonEncode({'Items': all, 'TotalRecordCount': all.length}),
          200,
        );
      }),
    )..session = syntheticSession();
    addTearDown(api.close);
  });
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    testWidgets('pinyin follows scrolling after a letter jump at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      bool selected(String letter) =>
          tester
              .widget<Semantics>(
                find.byWidgetPredicate(
                  (w) => w is Semantics && w.properties.label == '拼音 $letter',
                ),
              )
              .properties
              .selected ==
          true;
      await tester.tap(find.byKey(const ValueKey('alphabet-letter-M')));
      await settleOffline(tester);
      expect(selected('M'), true);
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 700));
      await settleOffline(tester);
      expect(
        selected('M'),
        false,
        reason: 'scrolling must replace the tapped letter',
      );
      controller.jumpTo(0);
      await settleOffline(tester);
      expect(selected('A'), true);
      controller.jumpTo(controller.position.maxScrollExtent);
      await settleOffline(tester);
      expect(selected('Z'), true);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
    });
    testWidgets(
      'system back closes detail then confirms exit without changing tabs at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = AppStore(prefs);
        await store.saveSession(api.session!);
        await tester.pumpWidget(YingyuApp(store: store, api: api));
        await settleOffline(tester);
        Future<void> tab(String label) async {
          await tester.tap(find.text(label).hitTestable().last);
          await settleOffline(tester);
        }

        int getIndex() =>
            tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index;
        await tab('媒体库');
        await tab('设置');
        await tab('媒体库');
        await tab('媒体库'); // Re-selecting a tab does not add a back step.
        await tester.tap(find.text('A0').hitTestable());
        await settleOffline(tester);
        expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
        await tester.binding.handlePopRoute();
        await settleOffline(tester);
        expect(find.byTooltip('关闭').hitTestable(), findsNothing);
        expect(getIndex(), 1);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(getIndex(), 1);
        expect(find.text('再按一次退出 app'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        store.dispose();
      },
    );
  }
}
