import 'offline_settle.dart';
import 'poster_test.dart' show RecordingCache;
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/alphabet_rail.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/settings.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  late SharedPreferences prefs;
  setUp(() async {
    syntheticImagePaths();
    final oldPoster = posterCache, oldArtwork = artworkCache;
    posterCache = RecordingCache();
    artworkCache = RecordingCache();
    addTearDown(() {
      posterCache = oldPoster;
      artworkCache = oldArtwork;
    });
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    testWidgets(
      'detail return preserves grid offset and fetched page at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var itemRequests = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/Users/synthetic-user')) {
              return response('{"Id":"synthetic-user"}', 200);
            }
            if (request.url.path.endsWith('/Views')) {
              return response('{"Items":[]}', 200);
            }
            if (request.url.path.endsWith('/Items')) {
              itemRequests++;
              return response(
                jsonEncode({
                  'Items': List.generate(
                    48,
                    (i) => {'Id': 'm$i', 'Name': '影片 $i', 'Type': 'Movie'},
                  ),
                  'TotalRecordCount': 48,
                }),
                200,
              );
            }
            return response('{}', 200);
          }),
        )..session = syntheticSession();
        final repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        final nav = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: nav,
            home: Scaffold(
              body: LibraryPage(
                api: api,
                browse: repo,
                onItem: (_) async {
                  await nav.currentState!.push(
                    MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                        body: Center(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('返回列表'),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await settleOffline(tester);
        if (size.width > size.height) {
          final rail = tester.getRect(
            find.byKey(const Key('alphabet-hit-area')),
          );
          final viewport = tester.getRect(find.byType(CustomScrollView));
          expect(rail.center.dy, closeTo(viewport.center.dy, 1));
          expect(rail.bottom, lessThanOrEqualTo(viewport.bottom));
          expect(
            find.byKey(const ValueKey('alphabet-letter-Z')).hitTestable(),
            findsOneWidget,
          );
          expect(find.byType(AlphabetRail), findsOneWidget);
        }
        final grid = find.byType(CustomScrollView);
        await tester.dragFrom(
          Offset(3, size.height - 140),
          const Offset(0, -1100),
        );
        await settleOffline(tester);
        final controller = tester.widget<CustomScrollView>(grid).controller!;
        final before = controller.offset;
        expect(
          before,
          greaterThan(0),
          reason: 'Empty left margin accepts scroll',
        );
        final card = find.byType(MediaCard).hitTestable().first;
        await tester.tap(card);
        await settleOffline(tester);
        await tester.tap(find.text('返回列表'));
        await settleOffline(tester);
        expect(controller.offset, before);
        expect(itemRequests, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        repo.dispose();
        api.close();
      },
    );
  }
  testWidgets(
    'continue watching view all keeps collapsed later pages across timed refresh and exact episode',
    (tester) async {
      final calls = <int>[];
      var now = DateTime.utc(2026, 10, 7);
      String? clicked;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Persons')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          if (request.url.path.endsWith('/Users/synthetic-user')) {
            return response('{"Id":"synthetic-user"}', 200);
          }
          final start =
              int.tryParse(request.url.queryParameters['StartIndex'] ?? '') ??
              0;
          calls.add(start);
          return response(
            jsonEncode({
              'Items': List.generate(
                start == 0 ? 48 : 32,
                (i) => {
                  'Id': 'ep${start + i}',
                  'Name': '继续 ${start + i}',
                  'Type': 'Episode',
                  'SeriesId': 'series${(start + i) ~/ 2}',
                  'UserData': {'PlaybackPositionTicks': 600000000},
                },
              ),
              'TotalRecordCount': 80,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final store = AppStore(prefs);
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
        now: () => now,
      );
      final feed = HomeFeed(api, store, browse: repo);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(
              api: api,
              browse: repo,
              resumeFeed: feed,
              onItem: (item) async => clicked = item.id,
            ),
          ),
        ),
      );
      await settleOffline(tester);
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      controller.jumpTo(controller.position.maxScrollExtent);
      await settleOffline(tester);
      expect(calls, [0, 48]);
      controller.jumpTo(0);
      await settleOffline(tester);
      now = now.add(repo.preferences.interval);
      await tester.pump(repo.preferences.interval);
      await settleOffline(tester);
      expect(calls, [0, 48, 0]);
      controller.jumpTo(controller.position.maxScrollExtent);
      await settleOffline(tester);
      await tester.tap(find.text('继续 78'));
      await settleOffline(tester);
      expect(clicked, 'ep78');
      await tester.pumpWidget(const SizedBox());
      feed.dispose();
      store.dispose();
      repo.dispose();
      api.close();
    },
  );
  testWidgets(
    'complete catalogue handles a server cap automatically and caches pinyin navigation',
    (tester) async {
      final starts = <int>[];
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Persons')) {
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }
          if (request.url.path.endsWith('/Users/synthetic-user')) {
            return response('{"Id":"synthetic-user"}', 200);
          }
          if (request.url.path.endsWith('/Views')) {
            return response('{"Items":[]}', 200);
          }
          final start =
              int.tryParse(request.url.queryParameters['StartIndex'] ?? '') ??
              0;
          final limit =
              int.tryParse(request.url.queryParameters['Limit'] ?? '') ?? 200;
          starts.add(start);
          final all = List.generate(
            205,
            (i) => {
              'Id': 'm$i',
              'Name': i == 204 ? '最后一部' : '阿丽塔 $i',
              'Type': 'Movie',
            },
          );
          return response(
            jsonEncode({
              'Items': all.skip(start).take(limit).toList(),
              'TotalRecordCount': 205,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      await tester.tap(find.byKey(const Key('library-sort')));
      await settleOffline(tester);
      await tester.tap(find.text('影片名称'));
      await settleOffline(tester);
      expect(starts, [0, 200]);
      await tester.tap(find.bySemanticsLabel('拼音 Z'));
      await settleOffline(tester);
      expect(
        find.text('最后一部').hitTestable(),
        findsOneWidget,
        reason:
            'offset=${tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!.offset}; cards=${tester.widgetList<MediaCard>(find.byType(MediaCard)).map((c) => c.item.title).toList()}',
      );
      expect(find.text('排序：拼音 A–Z · 205 项'), findsOneWidget);
      final before = starts.length;
      await tester.enterText(find.byType(EditableText), 'zhy');
      await settleOffline(tester);
      expect(find.text('最后一部'), findsOneWidget);
      expect(starts.length, before);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
    },
  );
  testWidgets(
    'automatic refresh waits its configured interval and stops in background or covered routes',
    (tester) async {
      var calls = 0;
      var now = DateTime.utc(2026, 10, 7);
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Users/synthetic-user')) {
            return response('{"Id":"synthetic-user"}', 200);
          }
          calls++;
          return response(
            request.url.path.endsWith('/Latest')
                ? '[{"Id":"movie"}]'
                : request.url.path.endsWith('/Views')
                ? '{"Items":[{"Id":"library","Name":"电影"}]}'
                : '{"Items":[]}',
            200,
          );
        }),
      )..session = syntheticSession();
      final store = AppStore(prefs);
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        now: () => now,
        spacing: Duration.zero,
      );
      final feed = HomeFeed(api, store, browse: repo);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: HomeDashboard(
              feed: feed,
              active: true,
              onItem: (_) async {},
              onPlay: (_) async {},
            ),
          ),
        ),
      );
      await settleOffline(tester);
      expect(calls, 3);
      now = now.add(repo.preferences.interval - const Duration(minutes: 1));
      await tester.pump(repo.preferences.interval - const Duration(minutes: 1));
      await settleOffline(tester);
      expect(calls, 3);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      await settleOffline(tester);
      expect(calls, 6);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(repo.preferences.interval);
      await tester.pump(repo.preferences.interval);
      await settleOffline(tester);
      expect(calls, 6);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settleOffline(tester);
      expect(calls, 9);
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('播放器占位')),
        ),
      );
      await settleOffline(tester);
      now = now.add(repo.preferences.interval);
      await tester.pump(repo.preferences.interval);
      await settleOffline(tester);
      expect(calls, 9);
      await tester.pumpWidget(const SizedBox());
      feed.dispose();
      store.dispose();
      repo.dispose();
      api.close();
    },
  );
  testWidgets('account is separate from playback and cache settings', (
    tester,
  ) async {
    final api = EmbyClient(
      client: MockClient(
        (request) async => response(
          request.url.path.endsWith('/Users/synthetic-user')
              ? '{"Id":"synthetic-user"}'
              : request.url.path.endsWith('/Latest')
              ? '[]'
              : '{"Items":[]}',
          200,
        ),
      ),
    )..session = syntheticSession();
    final store = AppStore(prefs);
    await store.saveSession(api.session!);
    await tester.pumpWidget(YingyuApp(store: store, api: api));
    await settleOffline(tester);
    final labels = ['首页', '媒体库', '设置', '账户'];
    final positions = [
      for (final label in labels)
        tester.getCenter(find.text(label).hitTestable().last).dx,
    ];
    expect(positions, orderedEquals([...positions]..sort()));
    await tester.tap(find.text('账户').hitTestable().last);
    await settleOffline(tester);
    expect(find.text('自动选择字幕').hitTestable(), findsNothing);
    await tester.tap(find.text('设置').hitTestable().last);
    await settleOffline(tester);
    // The added home-order card pushes playback below this short viewport.
    await tester.scrollUntilVisible(
      find.text('自动选择字幕').hitTestable(),
      180,
      scrollable: find
          .descendant(
            of: find.byType(SettingsPage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await settleOffline(tester);
    expect(find.text('自动选择字幕').hitTestable(), findsOneWidget);
    expect(find.byTooltip('刷新首页'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    api.close();
  });
}
