import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'core_test.dart' show syntheticSession, response;
import 'detail_anchor117_test.dart' show episode;
import 'phone_layout_test.dart' show setDisplay;
import 'offline_capture.dart';
import 'offline_settle.dart';
import 'player_episode_menu_test.dart' show fonts;
import 'package:visibility_detector/visibility_detector.dart';

void main() {
  setUpAll(fonts);
  setUp(() { syntheticImagePaths(); VisibilityDetectorController.instance.updateInterval = Duration.zero; });
  for (final size in [
    const Size(390, 844),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    testWidgets(
      'synopsis plays the watched episode and defers compact list anchor $size',
      (tester) async {
        setDisplay(tester, size);
        var played = '';
        final playback = Completer<void>();
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
                  'Items': List.generate(45, (n) => episode(n + 1).data),
                  'TotalRecordCount': 45,
                }),
                200,
              );
            }
            return response(
              '{"Id":"s","Type":"Series","Name":"Series fixture","Overview":"Synopsis preview"}',
              200,
            );
          }),
        )..session = syntheticSession();
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: boundary,
              child: DetailPage(
                item: MediaItem({
                  'Id': 's',
                  'Type': 'Series',
                  'Name': 'Series fixture',
                }),
                api: api,
                resumeEpisode: episode(26),
                watchedEpisode: (_) async => episode(26),
                play: (item, source, beginning) async {
                  played = item.id;
                  expect(beginning, false);
                  await playback.future;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(played, isEmpty);
        if (size.width < size.height) {
          expect(
            tester
                .widget<CupertinoSlidingSegmentedControl<int>>(
                  find.byType(CupertinoSlidingSegmentedControl<int>),
                )
                .groupValue,
            0,
          );
        }
        final button = find.byKey(const Key('synopsis-play'));
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await captureOffline(
          tester,
          boundary,
          'detail154-synopsis-${size.width.toInt()}',
        );
        await tester.tap(button);
        await tester.pump();
        expect(played, 'e26');
        expect(find.textContaining('正在打开'), findsOneWidget);
        playback.complete();
        await tester.pumpAndSettle();
        if (size.width < size.height) {
          await tester.tap(find.text('剧集'));
          await tester.pumpAndSettle();
        }
        expect(
          find.byKey(const ValueKey('detail-episode-e26')).hitTestable(),
          findsOneWidget,
        );
        await captureOffline(
          tester,
          boundary,
          'detail154-episodes-${size.width.toInt()}',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.close();
      },
    );
  }
}
