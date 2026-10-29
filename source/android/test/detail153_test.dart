import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'core_test.dart' show response, syntheticSession;
import 'offline_settle.dart' show syntheticImagePaths;

final series = MediaItem({
  'Id': 'series',
  'Type': 'Series',
  'Name': 'Synthetic series',
});
final episode = MediaItem({
  'Id': 'episode17',
  'Type': 'Episode',
  'Name': 'Synthetic episode seventeen',
  'SeriesId': 'series',
  'SeasonId': 'season',
  'IndexNumber': 17,
  'ParentIndexNumber': 1,
});

Future<void> showDetail(
  WidgetTester tester,
  EmbyClient api, {
  BrowseRepository? browse,
  MediaItem? watched,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: DetailPage(
        item: series,
        api: api,
        browse: browse,
        watchedEpisode: (_) async => watched,
        play: (_, _, _) async {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    syntheticImagePaths();
  });

  testWidgets(
    'successful detail and watched episodes survive failed seasons; retry is scoped honestly',
    (tester) async {
      var failSeasons = true, detailCalls = 0, episodeCalls = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Seasons')) {
            return failSeasons
                ? response('{"Message":"Synthetic season failure"}', 503)
                : response(
                    '{"Items":[{"Id":"season","Name":"Season one","IndexNumber":1}]}',
                    200,
                  );
          }
          if (request.url.path.endsWith('/Episodes')) {
            episodeCalls++;
            return response(
              jsonEncode({
                'Items': [episode.data],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          detailCalls++;
          return response(
            jsonEncode({
              ...series.data,
              'Overview': 'Fresh successful overview',
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      await showDetail(tester, api, watched: episode);
      await tester.pumpAndSettle();
      expect(detailCalls, 1);
      expect(find.text('Fresh successful overview'), findsOneWidget);
      expect(
        find.textContaining('更新失败，显示本机缓存'),
        findsNothing,
        reason: 'new HTTP 200 detail must not be labelled stale or failed',
      );
      expect(find.textContaining('季列表读取失败'), findsOneWidget);
      expect(episodeCalls, 1, reason: 'known watched season remains usable');
      expect(
        find.byKey(const ValueKey('detail-episode-episode17')),
        findsOneWidget,
      );
      failSeasons = false;
      await tester.tap(find.textContaining('季列表读取失败'));
      await tester.pumpAndSettle();
      expect(detailCalls, 2);
      expect(find.textContaining('季列表读取失败'), findsNothing);
      expect(find.text('Season one'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pausing browse after detail success is cancellation, then resuming reloads the panels',
    (tester) async {
      final gate = Completer<void>();
      var seasonCalls = 0, detailCalls = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Seasons')) {
            seasonCalls++;
            if (seasonCalls == 1) await gate.future;
            return response(
              '{"Items":[{"Id":"season","Name":"Season one","IndexNumber":1}]}',
              200,
            );
          }
          if (request.url.path.endsWith('/Episodes')) {
            return response(
              jsonEncode({
                'Items': [episode.data],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          detailCalls++;
          return response(
            jsonEncode({
              ...series.data,
              'Overview': 'Fresh successful overview',
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final prefs = await SharedPreferences.getInstance();
      final browse = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      addTearDown(() {
        browse.dispose();
        api.close();
      });
      await showDetail(tester, api, browse: browse);
      for (var i = 0; i < 10 && seasonCalls == 0; i++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      expect(seasonCalls, 1);
      expect(detailCalls, 1);
      expect(find.text('Fresh successful overview'), findsOneWidget);
      browse.suspend();
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('更新失败，显示本机缓存'), findsNothing);
      expect(find.textContaining('读取失败'), findsNothing);
      expect(find.text('剧集读取已暂停'), findsOneWidget);
      expect(find.text('暂无可用剧集'), findsNothing);
      browse.activate();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(seasonCalls, 2);
      expect(find.text('Season one'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('detail-episode-episode17')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed empty season panel has a working retry', (tester) async {
    var fails = true, seasonCalls = 0;
    final api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/Seasons')) {
          seasonCalls++;
          return fails
              ? response('{"Message":"Synthetic season failure"}', 503)
              : response(
                  '{"Items":[{"Id":"season","Name":"Season one","IndexNumber":1}]}',
                  200,
                );
        }
        if (request.url.path.endsWith('/Episodes')) {
          return response(
            jsonEncode({
              'Items': [episode.data],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }
        return response(
          jsonEncode({...series.data, 'Overview': 'Fresh successful overview'}),
          200,
        );
      }),
    )..session = syntheticSession();
    addTearDown(api.close);
    await showDetail(tester, api);
    await tester.pumpAndSettle();
    expect(find.textContaining('更新失败，显示本机缓存'), findsNothing);
    expect(find.textContaining('季列表读取失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    fails = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(seasonCalls, 2);
    expect(find.textContaining('季列表读取失败'), findsNothing);
    expect(
      find.byKey(const ValueKey('detail-episode-episode17')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a real detail failure still shows failure and retry', (
    tester,
  ) async {
    var fails = true;
    final api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/Seasons')) {
          return response('{"Items":[]}', 200);
        }
        return fails
            ? response('{"Message":"Synthetic detail failure"}', 503)
            : response(
                jsonEncode({
                  ...series.data,
                  'Overview': 'Fresh successful overview',
                }),
                200,
              );
      }),
    )..session = syntheticSession();
    addTearDown(api.close);
    await showDetail(tester, api);
    await tester.pumpAndSettle();
    expect(find.textContaining('更新失败，显示本机缓存'), findsOneWidget);
    expect(find.text('演职员读取失败，请重试'), findsOneWidget);
    fails = false;
    await tester.tap(find.text('重试演职员'));
    await tester.pumpAndSettle();
    expect(find.textContaining('更新失败，显示本机缓存'), findsNothing);
    expect(find.text('Fresh successful overview'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
