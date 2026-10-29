import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/personal_sync.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/home_order.dart';
import 'package:yingyu/ui/poster_actions.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show response, syntheticSession;
import 'cache_settings_test.dart' show fonts;
import 'offline_settle.dart' show settleOffline;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'all five accents change actions while poster text stays neutral $brightness',
      (tester) async {
        await fonts();
        final store = AppStore(await SharedPreferences.getInstance());
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/Views')) {
              return response('{"Items":[{"Id":"movies","Name":"电影"}]}', 200);
            }
            if (request.url.path.endsWith('/Latest')) {
              return response(
                jsonEncode([
                  {'Id': 'm', 'Name': '海报片名保持文字色', 'Type': 'Movie'},
                ]),
                200,
              );
            }
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }),
        )..session = syntheticSession();
        final feed = HomeFeed(api, store),
            sync = PersonalSync(api, store.personal),
            preferences = InterfacePreferences(store.prefs);
        final key = GlobalKey();
        for (final accent in AppAccent.available) {
          final theme = appTheme(brightness, accentChoice: accent);
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
                home: Scaffold(
                  body: PosterActionsScope(
                    sync: sync,
                    preferences: preferences,
                    feed: feed,
                    onItem: (_) async {},
                    child: HomeDashboard(
                      feed: feed,
                      active: true,
                      onItem: (_) async {},
                      onPlay: (_) async {},
                      onSearch: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          for (final id in ['home-search', 'home-refresh', 'poster-more-m']) {
            final icon = tester.widget<Icon>(
              find
                  .descendant(
                    of: find.byKey(ValueKey(id)),
                    matching: find.byType(Icon),
                  )
                  .first,
            );
            expect(icon.color, accent.color(brightness));
          }
          final painter = tester
              .widget<CustomPaint>(
                find.descendant(
                  of: find.byType(HomeSectionOrderIcon),
                  matching: find.byType(CustomPaint),
                ),
              )
              .painter;
          expect((painter as dynamic).color, accent.color(brightness));
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text('海报片名保持文字色'),
          );
          expect(paragraph.text.style!.color, theme.colorScheme.onSurface);
          expect(paragraph.text.style!.color, isNot(accent.color(brightness)));
          expect(tester.takeException(), isNull);
          if (accent == AppAccent.rose || accent == AppAccent.emerald) {
            await tester.runAsync(() async {
              final picture =
                  await (key.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await picture.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/ui-previews/$appVersion-action-accent-${accent.name}-${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              picture.dispose();
            });
          }
        }
        await tester.pumpWidget(const SizedBox());
        feed.dispose();
        sync.dispose();
        preferences.dispose();
        api.close();
        store.dispose();
      },
    );
  }
}
