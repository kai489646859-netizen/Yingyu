import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'cache_settings_test.dart' show fonts;
import 'core_test.dart' show response, syntheticSession;
import 'home_feed_test.dart' show entry;

void main() {
  testWidgets(
    'view-all resume menu stays in poster bottom-right and preserves central play',
    (tester) async {
      final interval = VisibilityDetectorController.instance.updateInterval;
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      addTearDown(
        () => VisibilityDetectorController.instance.updateInterval = interval,
      );
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final item = entry('all-movie');
      var removed = false, plays = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/HideFromResume')) {
            removed = true;
            return response(jsonEncode(item.data['UserData']), 200);
          }
          return response(
            jsonEncode({
              'Items': removed ? [] : [item.data],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store)..resume = [item];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(
              api: api,
              resumeFeed: feed,
              onItem: (_) async {},
              onPlay: (_) async {
                plays++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final more = find.byKey(const Key('resume-menu-all-movie'));
      final anchor = tester.getRect(more),
          poster = tester.getRect(find.byType(Poster));
      expect(anchor.right, closeTo(poster.right, .01));
      expect(anchor.bottom, closeTo(poster.bottom - 4, .01));
      await tester.tap(find.byKey(const Key('resume-play-all-movie')));
      await tester.pumpAndSettle();
      expect(plays, 1);
      await tester.tap(more);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('resume-remove-all-movie')));
      await tester.pumpAndSettle();
      expect(more, findsNothing);
      expect(item.resume, const Duration(seconds: 60));
      await tester.pumpWidget(const SizedBox());
      feed.dispose();
      api.close();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [412.0, 1280.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'resume menu uses only more button and retains progress width=$width dark=$dark',
        (tester) async {
          tester.view.physicalSize = Size(width, 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final interval = VisibilityDetectorController.instance.updateInterval;
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          addTearDown(
            () =>
                VisibilityDetectorController.instance.updateInterval = interval,
          );
          await fonts();
          SharedPreferences.setMockInitialValues({});
          final store = AppStore(await SharedPreferences.getInstance());
          var removed = false, details = 0, plays = 0;
          final item = entry('preview-movie');
          final api = EmbyClient(
            client: MockClient((request) async {
              if (request.url.path.endsWith('/HideFromResume')) {
                removed = true;
                return response(jsonEncode(item.data['UserData']), 200);
              }
              return response(
                jsonEncode({
                  'Items': removed ? [] : [item.data],
                }),
                200,
              );
            }),
          )..session = syntheticSession();
          final feed = HomeFeed(api, store)..resume = [item];
          final capture = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(dark ? Brightness.dark : Brightness.light),
                home: Scaffold(
                  body: SafeArea(
                    child: ListView(
                      children: [
                        const SizedBox(height: 50),
                        AnimatedBuilder(
                          animation: feed,
                          builder: (_, _) => ContinueWatching(
                            feed: feed,
                            active: true,
                            onPlay: (_) async {
                              plays++;
                            },
                            onDetail: (_) async {
                              details++;
                            },
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
          await tester.tap(find.byKey(const ValueKey('resume-preview-movie')));
          await tester.pumpAndSettle();
          expect(details, 1);
          expect(find.text('移出“继续观看”'), findsNothing);
          await tester.tap(
            find.byKey(const ValueKey('resume-play-preview-movie')),
          );
          await tester.pumpAndSettle();
          expect(plays, 1);
          final trigger = find.byKey(
            const ValueKey('resume-menu-preview-movie'),
          );
          final anchor = tester.getRect(trigger);
          final poster = tester.getRect(find.byType(Poster));
          expect(anchor.right, closeTo(poster.right, .01));
          expect(anchor.bottom, closeTo(poster.bottom - 4, .01));
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          final choice = find.byKey(
            const ValueKey('resume-remove-preview-movie'),
          );
          expect(choice, findsOneWidget);
          final bounds = tester.getRect(choice);
          expect(bounds.width, lessThan(220));
          expect(bounds.height, lessThanOrEqualTo(52));
          expect(bounds.top, greaterThanOrEqualTo(anchor.bottom));
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(width));
          await tester.runAsync(() async {
            final image =
                await (capture.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/ui-previews/$appVersion-resume-remove-${width.toInt()}-${dark ? 'dark' : 'light'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
          await tester.tap(choice);
          await tester.pumpAndSettle();
          expect(removed, true);
          expect(feed.resume, isEmpty);
          expect(item.resume, const Duration(seconds: 60));
          expect(find.text('已移出继续观看，观看进度保留'), findsOneWidget);
          expect(details, 1);
          expect(plays, 1);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          feed.dispose();
          api.close();
        },
      );
    }
  }
}
