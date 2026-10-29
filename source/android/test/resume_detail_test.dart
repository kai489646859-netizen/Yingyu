import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  setUp(
    () => VisibilityDetectorController.instance.updateInterval = Duration.zero,
  );
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    for (final number in [26, 59]) {
      for (final hint in [false, true]) {
        testWidgets(
          'detail selects exact season and episode $number hint=$hint at $size without opening media',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final calls = <Uri>[];
            MediaItem ep(int n) => MediaItem({
              'Id': 'ep$n',
              'Type': 'Episode',
              'Name': '第二季 第$n集',
              'SeriesId': 'series',
              'SeasonId': 's2',
              'ParentIndexNumber': 2,
              'IndexNumber': n,
            });
            final api = EmbyClient(
              client: MockClient((r) async {
                calls.add(r.url);
                if (r.url.queryParameters['SortBy'] == 'DatePlayed') {
                  return response(
                    jsonEncode({
                      'Items': [
                        {
                          ...ep(number).data,
                          'UserData': {
                            'LastPlayedDate': '2026-10-07T08:00:00Z',
                            'PlaybackPositionTicks': 600000000,
                          },
                        },
                      ],
                    }),
                    200,
                  );
                }
                if (r.url.path.endsWith('/Seasons')) {
                  return response(
                    jsonEncode({
                      'Items': [
                        {'Id': 's1', 'Name': '第一季', 'IndexNumber': 1},
                        {'Id': 's2', 'Name': '第二季', 'IndexNumber': 2},
                      ],
                    }),
                    200,
                  );
                }
                if (r.url.path.endsWith('/Episodes')) {
                  return response(
                    jsonEncode({
                      'Items': List.generate(80, (i) => ep(i + 1).data),
                      'TotalRecordCount': 80,
                    }),
                    200,
                  );
                }
                if (r.url.path.endsWith('/series')) {
                  return response(
                    '{"Id":"series","Type":"Series","Name":"合成剧集"}',
                    200,
                  );
                }
                fail('Unexpected request: ${r.url.path}');
              }),
            )..session = syntheticSession();
            String? played;
            await tester.pumpWidget(
              MaterialApp(
                theme: appTheme(Brightness.light),
                home: DetailPage(
                  item: MediaItem({'Id': 'series', 'Type': 'Series'}),
                  resumeEpisode: hint ? ep(number) : null,
                  api: api,
                  play: (entry, _, _) async => played = entry.id,
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(played, null);
            final episodeCalls = calls.where(
              (u) => u.path.endsWith('/Episodes'),
            );
            expect(episodeCalls.length, 1);
            expect(episodeCalls.single.queryParameters['SeasonId'], 's2');
            if (size.width < size.height) {
              expect(
                tester
                    .widget<CupertinoSlidingSegmentedControl<int>>(
                      find.byType(CupertinoSlidingSegmentedControl<int>),
                    )
                    .groupValue,
                0,
              );
              await tester.tap(find.text('剧集'));
              await tester.pumpAndSettle();
            }
            final target = find.byKey(ValueKey('detail-episode-ep$number'));
            expect(target.hitTestable(), findsOneWidget);
            await tester.tap(target);
            await tester.pumpAndSettle();
            expect(played, 'ep$number');
            expect(tester.takeException(), null);
            await tester.pumpWidget(const SizedBox());
            api.close();
          },
        );
      }
    }
  }
  testWidgets('resume all card has separate detail and play hit targets', (
    tester,
  ) async {
    final api = EmbyClient()..session = syntheticSession();
    var plays = 0, details = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 380,
              height: 140,
              child: MediaCard(
                item: MediaItem({
                  'Id': 'episode',
                  'Type': 'Episode',
                  'Name': '测试',
                }),
                api: api,
                active: false,
                onTap: () => details++,
                onPlay: () => plays++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('测试'));
    expect(details, 1);
    expect(plays, 0);
    await tester.tap(find.byKey(const ValueKey('resume-play-episode')));
    expect(details, 1);
    expect(plays, 1);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
