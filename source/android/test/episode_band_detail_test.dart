import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/style.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'core_test.dart' show syntheticSession, response;
import 'detail_anchor117_test.dart' show episode;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

void main() {
  setUpAll(fonts);
  setUp(() {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  for (final size in [
    const Size(360, 800),
    const Size(800, 360),
    const Size(800, 1280),
    const Size(1280, 800),
  ]) {
    for (final dark in [false, true]) {
      testWidgets('detail range popup $size dark=$dark', (tester) async {
        setDisplay(tester, size);
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/Seasons')) {
              return response(
                '{"Items":[{"Id":"season","IndexNumber":1}]}',
                200,
              );
            }
            if (r.url.path.endsWith('/Episodes')) {
              return response(
                jsonEncode({
                  'Items': List.generate(8, (n) => episode(n + 1).data),
                  'TotalRecordCount': 8,
                }),
                200,
              );
            }
            return response('{"Id":"s","Type":"Series","Name":"合成剧集"}', 200);
          }),
        )..session = syntheticSession();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              theme: appTheme(dark ? Brightness.dark : Brightness.light),
              home: DetailPage(
                item: MediaItem({'Id': 's', 'Type': 'Series', 'Name': '合成剧集'}),
                api: api,
                play: (_, _, _) async {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (find.text('剧集').evaluate().isNotEmpty) {
          await tester.tap(find.text('剧集'));
          await tester.pumpAndSettle();
        }
        final trigger = find.byKey(const Key('episode-ranges-all'));
        final anchor = tester.getRect(trigger);
        await tester.tap(trigger);
        await tester.pumpAndSettle();
        final panel = tester.getRect(
          find.byKey(const Key('anchored-menu-panel')),
        );
        expect(panel.height, lessThanOrEqualTo(60));
        expect(panel.right, closeTo(anchor.right.clamp(0.0, size.width - 8), .1));
        expect(
          (panel.top - anchor.bottom).abs() < .1 ||
              (panel.bottom - anchor.top).abs() < .1,
          isTrue,
        );
        await captureOffline(
          tester,
          boundary,
          'menus214-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
        );
        await tester.tap(find.text('1–8').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('anchored-menu-panel')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.close();
      });
    }
  }
}
