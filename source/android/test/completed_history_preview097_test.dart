// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show response, syntheticSession;

void main() {
  var fontsReady = false;
  setUp(() {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  for (final wide in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
        'server supplied completed row ${wide ? 'tablet' : 'phone'} ${dark ? 'dark' : 'light'}',
        (tester) async {
          if (!fontsReady) {
            for (final font in {
              'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
              'packages/cupertino_icons/CupertinoIcons':
                  'packages/cupertino_icons/assets/CupertinoIcons.ttf',
            }.entries) {
              await (FontLoader(
                font.key,
              )..addFont(rootBundle.load(font.value))).load();
            }
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
            fontsReady = true;
          }
          tester.view.physicalSize = wide
              ? const Size(1280, 800)
              : const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final store = AppStore(await SharedPreferences.getInstance());
          await store.log.setEnabled(false);
          late MediaItem item;
          final api = EmbyClient(
            client: MockClient(
              (_) async => response(
                jsonEncode({
                  'Items': [item.data],
                }),
                200,
              ),
            ),
          )..session = syntheticSession();
          item = MediaItem({
            'Id': 'ep8',
            'Name': '合成第8集',
            'Type': 'Episode',
            'SeriesId': 'series',
            'SeriesName': '合成剧集',
            'ParentIndexNumber': 1,
            'IndexNumber': 8,
            'RunTimeTicks': 6000000000,
            'UserData': {'Played': true, 'PlaybackPositionTicks': 0},
          });
          var feed = HomeFeed(api, store);
          await store.prefs.setString(
            feed.cacheKey,
            jsonEncode({
              'items': [
                {
                  'item': item.data,
                  'observedAt': DateTime.now()
                      .subtract(const Duration(hours: 2))
                      .toIso8601String(),
                },
              ],
            }),
          );
          feed.dispose();
          feed = HomeFeed(api, store);
          await feed.refreshResume(force: true);
          expect(feed.resume.single.id, 'ep8');
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(dark ? Brightness.dark : Brightness.light),
                home: Scaffold(
                  body: SafeArea(
                    child: ContinueWatching(
                      feed: feed,
                      active: false,
                      onPlay: (_) async {},
                      onDetail: (_) async {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('已看完 · 1季8集'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/$appVersion-history-${wide ? 'tablet' : 'phone'}-${dark ? 'dark' : 'light'}.png',
            )..parent.createSync(recursive: true);
            file.writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 600));
          feed.dispose();
          api.close();
          await store.log.flush();
          store.log.dispose();
          store.dispose();
        },
      );
    }
  }
}
