import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/core/emby.dart';
import 'package:http/testing.dart';
import 'core_test.dart' show syntheticSession, response;
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/style.dart';
import 'player_episode_menu_test.dart' show fonts;

void main() {
  late AppStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
  });
  tearDown(() {
    store.log.dispose();
    store.dispose();
  });
  for (final size in [
    const Size(412, 915),
    const Size(915, 412),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'removed spoiler option leaves synopsis visible with legacy preference at $size',
      (tester) async {
        await fonts();
        await store.prefs.setBool('yingyu.browse.hideSpoilers.v1', true);
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        final api = EmbyClient(
          client: MockClient(
            (_) async => response(
              '{"Id":"preview","Type":"Episode","Overview":"下一集的故事简介"}',
              200,
            ),
          ),
        )..session = syntheticSession();
        addTearDown(api.close);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final capture = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            home: RepaintBoundary(
              key: capture,
              child: Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: DetailPage(
                      store: store,
                      api: api,
                      item: MediaItem({'Id': 'preview', 'Type': 'Episode'}),
                      play: (_, _, _) async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('未看剧情已隐藏 · 点击查看'), findsNothing);
        expect(find.text('下一集的故事简介'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui-previews/1.3.3-synopsis-${size.width.toInt()}x${size.height.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
