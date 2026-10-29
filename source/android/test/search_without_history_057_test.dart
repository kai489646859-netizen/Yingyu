import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'cache_settings_test.dart' show fonts;
import 'offline_settle.dart';

void main() {
  for (final size in [const Size(360, 740), const Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      testWidgets('search has no history with keyboard at $size $brightness', (
        tester,
      ) async {
        syntheticImagePaths();
        await fonts();
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final legacyKey =
            'yingyu.search-history.v1.${accountKey(syntheticSession())}';
        const legacy = '{"enabled":true,"entries":["旧搜索记录"]}';
        await prefs.setString(legacyKey, legacy);
        final api = EmbyClient(
          client: MockClient(
            (_) async => response('{"Items":[],"TotalRecordCount":0}', 200),
          ),
        )..session = syntheticSession();
        final repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        await repo.cache.put(
          repo.key('views'),
          ItemPage([], 0),
          DateTime.now(),
        );
        await repo.cache.put(
          repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
          ItemPage([], 0),
          DateTime.now(),
        );
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(() {
          tester.view.resetViewInsets();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(brightness),
            home: RepaintBoundary(
              key: boundary,
              child: Scaffold(
                body: SafeArea(
                  child: LibraryPage(
                    api: api,
                    browse: repo,
                    searchMode: true,
                    onItem: (_) async {},
                  ),
                ),
              ),
            ),
          ),
        );
        await settleOffline(tester);
        expect(find.byKey(const Key('inline-search-history')), findsNothing);
        expect(find.text('搜索历史'), findsNothing);
        expect(find.text('旧搜索记录'), findsNothing);
        expect(prefs.getString(legacyKey), legacy);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui-previews/$appVersion-search-no-history-${size.width.toInt()}-${brightness.name}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        repo.dispose();
        api.close();
      });
    }
  }
}
