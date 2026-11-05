import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/video_labels.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/media_versions.dart';
import 'package:yingyu/ui/resource_tags.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

Json source(String id, bool dolby) => {
  'Id': id,
  'Name': 'PRIVATE_ORIGINAL_FILENAME_2160p.mkv',
  'MediaStreams': [
    {
      'Type': 'Video',
      'Width': dolby ? 3840 : 1920,
      'Height': dolby ? 2160 : 1080,
      if (dolby) 'DoviProfile': 8 else 'VideoRange': 'HDR10',
    },
  ],
};

void main() {
  setUpAll(fonts);
  setUp(() {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  test(
    'concise names never use original filenames or invent unknown formats',
    () {
      expect(
        resourceName(
          resourceVideo(
            MediaItem({
              'MediaSources': [source('a', true)],
            }),
          ),
        ),
        '4K 杜比',
      );
      expect(
        resourceName(
          resourceVideo(
            MediaItem({
              'MediaSources': [source('b', false)],
            }),
          ),
        ),
        '1080p HDR10',
      );
      expect(resourceName({}), '格式未知');
      expect(
        resourceName({'Width': 1920, 'Height': 1080, 'VideoRange': 'SDR'}),
        '1080p',
      );
    },
  );
  testWidgets(
    'same technical labels remain distinct source choices without filenames',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaVersions(
            sources: [source('a', true), source('b', true)],
            selected: 'a',
            onSelected: (id) => selected = id,
          ),
        ),
      );
      expect(find.text('4K 杜比 · 版本1'), findsOneWidget);
      expect(find.text('4K 杜比 · 版本2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('media-version-b')));
      expect(selected, 'b');
      expect(find.textContaining('PRIVATE_ORIGINAL_FILENAME'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final size in [
    const Size(320, 740),
    const Size(800, 360),
    const Size(800, 1280),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'series tags use exact episode and chosen source $size scale=$scale',
        (tester) async {
          setDisplay(tester, size);
          final first = {
            'Id': 'e1',
            'Type': 'Episode',
            'SeriesId': 'show',
            'SeasonId': 'season',
            'IndexNumber': 1,
            'ParentIndexNumber': 1,
            'Name': '第一集',
            'MediaSources': [source('e1-dv', true), source('e1-hdr', false)],
          };
          final second = {
            'Id': 'e2',
            'Type': 'Episode',
            'SeriesId': 'show',
            'SeasonId': 'season',
            'IndexNumber': 2,
            'Name': '第二集',
            'MediaSources': <Json>[],
          };
          final series = {
            'Id': 'show',
            'Type': 'Series',
            'Name': '合成电视剧',
            'CommunityRating': 8.6,
            'ProductionYear': 2026,
            'Genres': ['剧情', '科幻'],
            'Overview': '手机和平板资源标签布局合成资料。',
          };
          final api = EmbyClient(
            client: MockClient((r) async {
              if (r.url.path.endsWith('/Seasons')) {
                return response(
                  '{"Items":[{"Id":"season","IndexNumber":1}]}',
                  200,
                );
              }
              if (r.url.path.endsWith('/Episodes')) {
                expect(
                  r.url.queryParameters['Fields'],
                  contains('MediaSources'),
                );
                expect(
                  r.url.queryParameters['Fields'],
                  contains('MediaStreams'),
                );
                return response(
                  jsonEncode({
                    'Items': [first, second],
                    'TotalRecordCount': 2,
                  }),
                  200,
                );
              }
              if (r.url.path.endsWith('/show')) {
                return response(jsonEncode(series), 200);
              }
              fail('Unexpected metadata or media request ${r.url.path}');
            }),
          )..session = syntheticSession();
          final wait = Completer<void>();
          String? played, playedSource;
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(scale == 1 ? Brightness.light : Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: DetailPage(
                  item: MediaItem(series),
                  api: api,
                  watchedEpisode: (_) async => MediaItem({
                    ...first,
                    'MediaSources': <Json>[],
                    'UserData': {'PlaybackPositionTicks': 600000000},
                  }),
                  play: (item, selected, _) async {
                    played = item.id;
                    playedSource = selected;
                    await wait.future;
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (find.text('简介').hitTestable().evaluate().isNotEmpty) {
            await tester.tap(find.text('简介').hitTestable().first);
            await tester.pumpAndSettle();
          }
          final tags = find.byKey(const Key('detail-resource-tags'));
          await tester.ensureVisible(tags);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: tags, matching: find.text('4K')),
            findsOneWidget,
          );
          expect(
            find.descendant(of: tags, matching: find.text('杜比')),
            findsOneWidget,
          );
          final play = find.byKey(const Key('synopsis-play'));
          expect(
            tester.getBottomLeft(tags).dy,
            lessThanOrEqualTo(tester.getTopLeft(play).dy),
          );
          final metadata = find.byKey(const Key('phone-detail-metadata'));
          expect(
            tester.getTopLeft(tags).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(metadata).dy),
          );
          final card = find.byKey(const ValueKey('media-version-e1-hdr'));
          await tester.ensureVisible(card);
          await tester.pumpAndSettle();
          await tester.tap(card);
          await tester.pumpAndSettle();
          expect(
            find.textContaining('PRIVATE_ORIGINAL_FILENAME'),
            findsNothing,
          );
          expect(
            tester
                .widget<Text>(find.byKey(const Key('selected-version-summary')))
                .data,
            '当前选择：1080p HDR10',
          );
          await tester.ensureVisible(tags);
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: tags, matching: find.text('HDR10')),
            findsOneWidget,
          );
          await tester.ensureVisible(metadata);
          await tester.pumpAndSettle();
          await captureOffline(
            tester,
            boundary,
            'resource219-${size.width.toInt()}x${size.height.toInt()}-$scale',
          );
          await tester.ensureVisible(play);
          await tester.pumpAndSettle();
          await tester.tap(play);
          await tester.pump();
          expect(played, 'e1');
          expect(playedSource, 'e1-hdr');
          wait.complete();
          await tester.pumpAndSettle();
          if (find.text('剧集').hitTestable().evaluate().isNotEmpty) {
            await tester.tap(find.text('剧集').hitTestable());
            await tester.pumpAndSettle();
          }
          final unknown = find.byKey(const ValueKey('episode-resource-e2'));
          final listScroll = find.descendant(
            of: find.byKey(const PageStorageKey('detail-episodes')),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(unknown, 60, scrollable: listScroll);
          await tester.pumpAndSettle();
          expect(tester.widget<ResourceTags>(unknown).video, isEmpty);
          final chooser = find.byKey(const ValueKey('episode-versions-e1'));
          await tester.scrollUntilVisible(chooser, -60, scrollable: listScroll);
          await tester.pumpAndSettle();
          await tester.tap(chooser);
          await tester.pumpAndSettle();
          final chosen = find
              .byKey(const ValueKey('media-version-e1-dv'))
              .hitTestable();
          await tester.tap(chosen);
          await tester.pumpAndSettle();
          expect(find.text('选择资源版本'), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          api.close();
        },
      );
    }
  }
}
