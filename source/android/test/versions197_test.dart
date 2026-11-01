import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/media_versions.dart';
import 'core_test.dart' show syntheticSession, response;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

final versions = <Json>[
  {
    'Id': 'dv',
    'Name': '4K 杜比视界原文件',
    'Size': 180020000000,
    'MediaStreams': [
      {
        'Type': 'Video',
        'Width': 3840,
        'Height': 2160,
        'DvProfile': 8,
        'Codec': 'hevc',
      },
    ],
  },
  {
    'Id': 'sdr',
    'Name': '1080p 普通版本',
    'Size': 12000000000,
    'MediaStreams': [
      {
        'Type': 'Video',
        'Width': 1920,
        'Height': 1080,
        'VideoRange': 'SDR',
        'Codec': 'h264',
      },
    ],
  },
  {
    'Id': 'hdr',
    'Name': '4K HDR10',
    'MediaStreams': [
      {
        'Type': 'Video',
        'Width': 3840,
        'Height': 2160,
        'VideoRangeType': 'HDR10',
      },
    ],
  },
];
void main() {
  setUpAll(fonts);
  setUp(() {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  test(
    'metadata uses actual selected stream and never guesses unknown Dolby',
    () {
      expect(mediaVersionFacts(versions[0]), contains('杜比视界'));
      expect(mediaVersionFacts(versions[0]), contains('180.02 GB'));
      expect(mediaVersionFacts(versions[1]), contains('1080p'));
      expect(mediaVersionFacts(versions[2]), contains('HDR10'));
      expect(mediaVersionFacts({'Name': 'Dolby 4K filename'}), '');
      expect(
        playableVersions(
          MediaItem({
            'MediaSources': [{}, versions[0], versions[0], versions[1]],
          }),
        ).length,
        2,
      );
    },
  );
  for (final size in [
    const Size(320, 740),
    const Size(800, 1280),
    const Size(1280, 800),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'detail source choice routes exact identity $size dark=$dark',
        (tester) async {
          setDisplay(tester, size);
          final movie = MediaItem({
            'Id': 'movie',
            'Type': 'Movie',
            'Name': '合成多版本影片',
            'Overview': '版本选择合成资料',
            'MediaSources': versions,
          });
          final api = EmbyClient(
            client: MockClient(
              (r) async => response(jsonEncode(movie.data), 200),
            ),
          )..session = syntheticSession();
          final wait = Completer<void>();
          String? played;
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: DetailPage(
                  item: movie,
                  api: api,
                  play: (item, source, beginning) async {
                    expect(item.id, 'movie');
                    played = source;
                    await wait.future;
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final rail = find.byType(MediaVersions);
          await tester.ensureVisible(rail);
          await tester.pumpAndSettle();
          expect(find.text('影片版本'), findsOneWidget);
          expect(
            tester.getTopLeft(rail).dy,
            greaterThan(
              tester.getTopLeft(find.byKey(const Key('synopsis-play'))).dy,
            ),
          );
          final card = find.byKey(const ValueKey('media-version-sdr'));
          await tester.ensureVisible(card);
          await tester.pumpAndSettle();
          await tester.tap(card);
          await tester.pumpAndSettle();
          expect(tester.widget<MediaVersions>(rail).selected, 'sdr');
          await captureOffline(
            tester,
            boundary,
            'versions197-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
          );
          final play = find.byKey(const Key('synopsis-play'));
          await tester.ensureVisible(play);
          await tester.pumpAndSettle();
          await tester.tap(play);
          await tester.pump();
          expect(played, 'sdr');
          expect(tester.widget<MediaVersions>(rail).enabled, false);
          wait.complete();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          api.close();
        },
      );
    }
  }
}
