import 'dart:convert';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  testWidgets(
    'server gaps and 500 records ending at 1816 keep exact fifty-episode bands',
    (tester) async {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final episodes = [
        for (var n = 1; n <= 501; n++)
          if (n != 50) n,
        1816,
      ];
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Seasons')) {
            return response('{"Items":[{"Id":"season","IndexNumber":1}]}', 200);
          }
          if (request.url.path.endsWith('/Episodes')) {
            return response(
              jsonEncode({
                'Items': [
                  for (final n in episodes)
                    {
                      'Id': 'e$n',
                      'Type': 'Episode',
                      'Name': '第$n集',
                      'IndexNumber': n,
                      'SeriesId': 'series',
                      'SeasonId': 'season',
                    },
                ],
                'TotalRecordCount': episodes.length,
              }),
              200,
            );
          }
          return response('{"Id":"series","Type":"Series","Name":"合成剧集"}', 200);
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      await tester.pumpWidget(
        CupertinoApp(
          home: DetailPage(
            item: MediaItem({'Id': 'series', 'Type': 'Series'}),
            api: api,
            watchedEpisode: (_) async => null,
            play: (_, _, _) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(DetailPage));
      expect(state.rangeLabel(0), '1–50');
      expect(state.rangeLabel(1), '51–100');
      expect(state.rangeLabel(9), '451–500');
      expect(state.rangeLabel(11), '1801–1816');
      expect(state.rangeCount, 12);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
