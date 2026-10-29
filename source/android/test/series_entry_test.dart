// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'offline_settle.dart';
import 'poster_test.dart' show RecordingCache;

void main() {
  for (final origin in ['latest-series', 'latest-episode', 'library']) {
    testWidgets(
      '$origin opens the last watched episode rather than the latest release',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        syntheticImagePaths();
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        final store = AppStore(await SharedPreferences.getInstance());
        final oldPoster = posterCache, oldArtwork = artworkCache;
        posterCache = RecordingCache();
        artworkCache = RecordingCache();
        addTearDown(() {
          posterCache = oldPoster;
          artworkCache = oldArtwork;
        });
        final series = {'Id': 'series', 'Type': 'Series', 'Name': '合成动漫'};
        final released = {
          'Id': 'ep99',
          'Type': 'Episode',
          'Name': '新到第99集',
          'SeriesId': 'series',
          'SeriesName': '合成动漫',
          'SeasonId': 's3',
          'ParentIndexNumber': 3,
          'IndexNumber': 99,
        };
        final watched = {
          'Id': 'ep59',
          'Type': 'Episode',
          'Name': '上次的第59集',
          'SeriesId': 'series',
          'SeasonId': 's2',
          'ParentIndexNumber': 2,
          'IndexNumber': 59,
          'UserData': {
            'PlaybackPositionTicks': 600000000,
            'LastPlayedDate': '2026-10-07T09:00:00Z',
          },
        };
        final paths = <Uri>[];
        final api = EmbyClient(
          client: MockClient((r) async {
            paths.add(r.url);
            if (r.url.path.endsWith('/Views')) {
              return response(
                '{"Items":[{"Id":"anime","Name":"动漫","IsFolder":true}]}',
                200,
              );
            }
            if (r.url.path.endsWith('/Resume')) {
              return response('{"Items":[]}', 200);
            }
            if (r.url.path.endsWith('/Latest')) {
              return response(
                jsonEncode([origin == 'latest-episode' ? released : series]),
                200,
              );
            }
            if (r.url.queryParameters['SortBy'] == 'DatePlayed') {
              return response(
                jsonEncode({
                  'Items': [watched],
                }),
                200,
              );
            }
            if (r.url.path.endsWith('/Items')) {
              return response(
                jsonEncode({
                  'Items': [series],
                  'TotalRecordCount': 1,
                }),
                200,
              );
            }
            if (r.url.path.endsWith('/series')) {
              return response(jsonEncode(series), 200);
            }
            if (r.url.path.endsWith('/Seasons')) {
              return response(
                '{"Items":[{"Id":"s1","Name":"第一季","IndexNumber":1},{"Id":"s2","Name":"第二季","IndexNumber":2}]}',
                200,
              );
            }
            if (r.url.path.endsWith('/Episodes')) {
              expect(r.url.queryParameters['SeasonId'], 's2');
              expect(r.url.queryParameters['StartItemId'], isNull);
              expect(r.url.queryParameters['Limit'], isNull);
              return response(
                jsonEncode({
                  'Items': [watched],
                  'TotalRecordCount': 1,
                }),
                200,
              );
            }
            fail('Unexpected metadata request ${r.url.path}');
          }),
        )..session = syntheticSession();
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: HomePage(
              api: api,
              store: store,
              createBackend: () =>
                  throw StateError('Browsing must not create a player'),
              logout: () async {},
            ),
          ),
        );
        await settleOffline(tester);
        if (origin == 'library') {
          await tester.tap(find.text('媒体库').hitTestable().last);
          await settleOffline(tester);
        }
        await tester.tap(
          find
              .text(origin == 'latest-episode' ? '新到第99集' : '合成动漫')
              .hitTestable()
              .first,
        );
        await settleOffline(tester);
        expect(find.byType(DetailPage), findsOneWidget);
        expect(
          find.byKey(const ValueKey('detail-episode-ep59')).hitTestable(),
          findsOneWidget,
        );
        expect(
          paths.every(
            (p) =>
                !p.path.contains('PlaybackInfo') &&
                !p.path.contains('/Videos/'),
          ),
          true,
        );
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox());
        api.close();
        store.dispose();
      },
    );
  }

  test(
    'last watched episode includes completed history and newer PC history wins over pending Android display',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      MediaItem episode(String id, DateTime date) => MediaItem({
        'Id': id,
        'Type': 'Episode',
        'SeriesId': 'series',
        'SeasonId': 'season',
        'UserData': {
          'Played': true,
          'LastPlayedDate': date.toIso8601String(),
          'PlaybackPositionTicks': 0,
        },
      });
      final local = episode(
        'local',
        DateTime.now().subtract(const Duration(minutes: 1)),
      );
      var remote = local;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Resume')) {
            return response('{"Items":[]}', 200);
          }
          if (r.url.queryParameters['SortBy'] == 'DatePlayed') {
            return response(
              jsonEncode({
                'Items': [remote.data],
              }),
              200,
            );
          }
          return response(jsonEncode(local.data), 200);
        }),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      await feed.afterPlayback(local);
      await store.saveProgress(
        api.session!,
        'local',
        const Duration(minutes: 2),
      );
      remote = episode(
        'older',
        DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect((await feed.lastWatchedEpisode('series'))!.id, 'older');
      remote = episode('pc', DateTime.now().add(const Duration(minutes: 1)));
      expect((await feed.lastWatchedEpisode('series'))!.id, 'pc');
      expect(feed.recentEpisode('other-series'), null);
      expect(
        store.localProgress(api.session!, 'local'),
        const Duration(minutes: 2),
      );
      feed.dispose();
      api.close();
      store.dispose();
    },
  );
}
