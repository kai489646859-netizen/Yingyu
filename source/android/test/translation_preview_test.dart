import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/offline_translation.dart';
import 'package:yingyu/ui/offline_translation.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/watch_progress.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession;

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'offline translation settings and episode progress preview dark=$dark',
      (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fontPath = Platform.environment['YINGYU_TEST_FONT'];
        if (fontPath != null) {
          for (final name in [
            'Roboto',
            'Ahem',
            '.SF UI Text',
            '.SF UI Display',
            'CupertinoSystemText',
            'CupertinoSystemDisplay',
          ]) {
            await (FontLoader(name)..addFont(
                  Future.value(
                    ByteData.sublistView(File(fontPath).readAsBytesSync()),
                  ),
                ))
                .load();
          }
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
              rootBundle.load(
                'packages/cupertino_icons/assets/CupertinoIcons.ttf',
              ),
            ))
            .load();
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final service = OfflineTranslation(prefs);
        final capture = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: RepaintBoundary(
              key: capture,
              child: Scaffold(
                body: SafeArea(
                  child: ListView(
                    children: [
                      OfflineTranslationGroup(service: service),
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('分集观看进度 · 合成示例'),
                            const SizedBox(height: 12),
                            for (final n in [1, 2, 3])
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('第 $n 集'),
                                    WatchProgress(
                                      account: syntheticSession(),
                                      item: MediaItem({
                                        'Id': '$n',
                                        'RunTimeTicks': 27000000000,
                                        'UserData': {
                                          'Played': n == 1,
                                          'PlaybackPositionTicks': n == 2
                                              ? 12500000000
                                              : 0,
                                        },
                                      }),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui-previews/$appVersion-translation-${dark ? 'dark' : 'light'}.png',
          )..parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        service.dispose();
      },
    );
  }
}
