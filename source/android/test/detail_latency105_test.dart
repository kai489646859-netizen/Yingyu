import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  for (final hint in [true, false]) {
    testWidgets(
      'watched episode hint=$hint appears before slow detail metadata',
      (tester) async {
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final detail = Completer<void>(), history = Completer<MediaItem?>();
        MediaItem ep(int n) => MediaItem({
          'Id': 'e$n',
          'Type': 'Episode',
          'Name': '合成第$n集',
          'SeriesId': 's',
          'SeasonId': 'season',
          'ParentIndexNumber': 1,
          'IndexNumber': n,
        });
        if (!hint) history.complete(ep(39));
        var requests = 0, played = 0;
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/Episodes')) {
              requests++;
              return response(
                jsonEncode({
                  'Items': List.generate(60, (i) => ep(i + 1).data),
                  'TotalRecordCount': 60,
                }),
                200,
              );
            }
            if (r.url.path.endsWith('/Seasons')) {
              return response(
                '{"Items":[{"Id":"season","IndexNumber":1}]}',
                200,
              );
            }
            await detail.future;
            return response('{"Id":"s","Type":"Series","Name":"合成剧"}', 200);
          }),
        )..session = syntheticSession();
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(
              item: MediaItem({'Id': 's', 'Type': 'Series', 'Name': '合成剧'}),
              resumeEpisode: hint ? ep(39) : null,
              watchedEpisode: (_) => history.future,
              api: api,
              play: (_, _, _) async {
                played++;
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump();
        expect(
          requests,
          1,
          reason: 'metadata waiting must not gate the known season',
        );
        expect(
          find.byKey(const ValueKey('detail-episode-e39')).hitTestable(),
          findsOneWidget,
        );
        detail.complete();
        if (!history.isCompleted) history.complete(ep(39));
        await tester.pumpAndSettle();
        expect(
          requests,
          1,
          reason: 'late metadata must not refetch or reset the same season',
        );
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('detail-episode-e39')),
            matching: find.byIcon(CupertinoIcons.play_circle),
          ),
        );
        await tester.pumpAndSettle();
        expect(played, 1);
        expect(
          requests,
          2,
          reason: 'returning from playback refreshes the season once',
        );
        await tester.pumpWidget(const SizedBox());
        api.close();
      },
    );
  }
}
