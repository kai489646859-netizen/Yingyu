import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/appearance.dart';
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
    const Size(320, 740),
    const Size(390, 844),
    const Size(1280, 800),
    const Size(800, 1280),
  ]) {
    for (final dark in [false, true]) {
      testWidgets(
        'resume button beside poster, themed, exact target $size dark=$dark',
        (tester) async {
          setDisplay(tester, size);
          final target = MediaItem({
            ...episode(26).data,
            'RunTimeTicks': 13200000000,
            'UserData': {'PlaybackPositionTicks': 2340000000},
          });
          MediaItem? played;
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
                jsonEncode({
                  'Id': 's',
                  'Type': 'Series',
                  'Name': '死亡笔记',
                  'ImageTags': {'Primary': 'fixture'},
                  'OriginalTitle': 'DEATH NOTE',
                  'Genres': ['动画', '悬疑', '科幻奇幻'],
                  'CommunityRating': 8.6,
                  'ProductionYear': 2006,
                  'RunTimeTicks': 13200000000,
                  'OfficialRating': 'TV-14',
                  'Overview': '合成简介，确认播放按钮不会落在演职员下方。',
                }),
                200,
              );
            }),
          )..session = syntheticSession();
          final boundary = GlobalKey();
          final theme = appTheme(
            dark ? Brightness.dark : Brightness.light,
            accentChoice: AppAccent
                .available[[320, 390, 1280, 800].indexOf(size.width.toInt())],
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: RepaintBoundary(
                key: boundary,
                child: DetailPage(
                  item: MediaItem({
                    'Id': 's',
                    'Type': 'Series',
                    'Name': '死亡笔记',
                  }),
                  api: api,
                  resumeEpisode: target,
                  watchedEpisode: (_) async => target,
                  play: (entry, source, beginning) async {
                    expect(beginning, false);
                    played = entry;
                    await playback.future;
                  },
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final button = find.byKey(const Key('synopsis-play'));
          expect(find.text('继续观看第 26 集'), findsOneWidget);
          final poster = tester.getRect(find.byKey(const Key('detail-poster')));
          final bounds = tester.getRect(button);
          expect(bounds.left, greaterThanOrEqualTo(poster.right));
          expect(bounds.bottom, closeTo(poster.bottom, .1));
          expect(bounds.height, lessThanOrEqualTo(36));
          expect(bounds.right, lessThanOrEqualTo(size.width));
          final control = tester.widget<CupertinoButton>(button);
          expect(control.color, theme.colorScheme.primary);
          expect(control.borderRadius, BorderRadius.circular(8));
          final label = tester.widget<Text>(find.text('继续观看第 26 集'));
          expect(label.style?.color, theme.colorScheme.onPrimary);
          await captureOffline(
            tester,
            boundary,
            'detail155-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
          );
          await tester.tap(button);
          await tester.pump();
          expect(played?.id, 'e26');
          expect(played?.resume, const Duration(seconds: 234));
          playback.complete();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          api.close();
        },
      );
    }
  }
  for (final series in [false, true]) {
    testWidgets(
      'unwatched ${series ? 'series' : 'movie'} says play, history wins before tap',
      (tester) async {
        setDisplay(tester, const Size(390, 844));
        final history = Completer<MediaItem?>();
        final playback = Completer<void>();
        final started = <String>[];
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
                  'Items': [episode(1).data],
                  'TotalRecordCount': 1,
                }),
                200,
              );
            }
            return response(
              jsonEncode({
                'Id': 's',
                'Type': series ? 'Series' : 'Movie',
                'Name': '未观看资源',
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(
              item: MediaItem({
                'Id': 's',
                'Type': series ? 'Series' : 'Movie',
                'Name': '未观看资源',
              }),
              api: api,
              watchedEpisode: (_) => history.future,
              play: (target, source, beginning) async {
                expect(beginning, false);
                started.add(target.id);
                await playback.future;
              },
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        if (series) {
          expect(
            tester
                .widget<CupertinoButton>(find.byKey(const Key('synopsis-play')))
                .onPressed,
            isNull,
          );
          expect(started, isEmpty);
          history.complete(null);
        }
        await tester.pumpAndSettle();
        expect(find.text('播放'), findsOneWidget);
        await tester.tap(find.byKey(const Key('synopsis-play')));
        await tester.pump();
        expect(started, [series ? 'e1' : 's']);
        playback.complete();
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.close();
      },
    );
  }
}
