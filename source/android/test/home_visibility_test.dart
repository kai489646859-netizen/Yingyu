import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/personal_status_page.dart';
import 'package:yingyu/core/personal_sync.dart';
import 'offline_settle.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/version_groups.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/home_order.dart';
import 'package:yingyu/ui/home_visibility.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:yingyu/ui/personal_library.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show response, syntheticSession;
import 'cache_settings_test.dart' show fonts;

class RejectedVisibilityPreferences extends InMemorySharedPreferencesStore {
  RejectedVisibilityPreferences() : super.withData({});
  @override
  Future<bool> setValue(String type, String key, Object value) async =>
      key.contains('yingyu.home.hidden.')
      ? false
      : super.setValue(type, key, value);
}

MediaItem member(String id, List<String> libraries) => MediaItem({
  'Id': id,
  'Name': id,
  'Type': 'Movie',
  '_YingyuLibraryIdsV1': libraries,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    syntheticImagePaths();
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  test(
    'visibility survives restart and isolates server and user without reading obsolete privacy records',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          account = syntheticSession();
      final order = HomeOrder(prefs);
      await prefs.setString(
        'yingyu.privacy.v1.${base64Url.encode(utf8.encode(accountKey(account)))}',
        '{broken',
      );
      expect(order.hidden(account), isEmpty);
      await order.saveHidden(account, {'private-folder'});
      final restored = HomeOrder(prefs);
      expect(restored.hidden(account), {'private-folder'});
      expect(
        restored.hidden(syntheticSession('https://another.invalid')),
        isEmpty,
      );
      final otherUser = Session(
        base: account.base,
        userId: 'other',
        username: account.username,
        token: account.token,
        deviceId: account.deviceId,
      );
      expect(restored.hidden(otherUser), isEmpty);
      await restored.saveHidden(account, {});
      expect(restored.hidden(account), isEmpty);
    },
  );
  test(
    'global visibility filters actual versions and shared membership and withholds unknown membership',
    () async {
      final order = HomeOrder(await SharedPreferences.getInstance()),
          account = syntheticSession();
      await order.saveHidden(account, {'hidden'});
      final group = VersionGroup(accountKey(account), [
        member('secret-version', ['hidden']),
        member('public-version', ['public']),
      ]);
      order.resolveMembership(
        account,
        [
          ...group.versions,
          member('both', ['public', 'hidden']),
        ],
        ['public', 'hidden'],
      );
      expect(
        order
            .visible(account, [
              group,
              member('both', ['public', 'hidden']),
              member('unknown', []),
            ])
            .map((e) => e.id),
        ['public-version'],
      );
    },
  );
  test('failed persistence keeps committed visibility', () async {
    final original = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = RejectedVisibilityPreferences();
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    final order = HomeOrder(await SharedPreferences.getInstance()),
        account = syntheticSession();
    await expectLater(
      order.saveHidden(account, {'a'}),
      throwsA(isA<AppFailure>()),
    );
    expect(order.hidden(account), isEmpty);
  });
  test(
    'unknown and stale metadata never bypass hidden folders; episodes inherit real series membership',
    () async {
      final order = HomeOrder(await SharedPreferences.getInstance()),
          account = syntheticSession();
      await order.saveHidden(account, {'hidden'});
      final stale = member('secret', ['public']);
      expect(order.allows(account, stale), false);
      order.resolveMembership(
        account,
        [
          member('secret', ['hidden']),
          member('series', ['hidden']),
          member('public', ['public']),
        ],
        ['hidden', 'public'],
      );
      expect(order.allows(account, stale), false);
      expect(
        order.allows(
          account,
          MediaItem({'Id': 'episode', 'SeriesId': 'series', 'Type': 'Episode'}),
        ),
        false,
      );
      expect(
        order.allows(account, member('public', ['hidden'])),
        true,
        reason: 'only the current complete folder catalogue grants visibility',
      );
      order.failResolution(account, 'synthetic unavailable');
      expect(
        order.allows(account, member('public', ['public'])),
        true,
        reason: 'a failed refresh retains the last verified membership',
      );
      expect(order.ready(account), true);
      await order.saveHidden(account, {});
      expect(order.allows(account, stale), true);
    },
  );
  testWidgets(
    'continue watching and saved films hide existing entries without erasing records',
    (tester) async {
      final store = AppStore(await SharedPreferences.getInstance()),
          api = EmbyClient()..session = syntheticSession();
      final feed = HomeFeed(api, store), account = api.session!;
      final secret = member('隐藏影片', ['hidden']),
          public = member('公开影片', ['public']);
      feed.resume = [secret, public];
      await store.personal.setSaved(account, SavedList.watchlist, secret, true);
      await store.personal.setSaved(account, SavedList.watchlist, public, true);
      await store.homeOrder.saveHidden(account, {'hidden'});
      store.homeOrder.resolveMembership(
        account,
        [secret, public],
        ['hidden', 'public'],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: HomeVisibilityScope(
            order: store.homeOrder,
            child: Scaffold(
              body: ContinueWatching(
                feed: feed,
                active: true,
                onPlay: (_) async {},
                onDetail: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('隐藏影片'), findsNothing);
      expect(find.text('公开影片'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeVisibilityScope(
            order: store.homeOrder,
            child: SavedMediaPage(
              library: store.personal,
              account: account,
              api: api,
              list: SavedList.watchlist,
              onItem: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('隐藏影片'), findsNothing);
      expect(find.text('公开影片'), findsOneWidget);
      expect(store.personal.items(account, SavedList.watchlist).length, 2);
      expect(feed.resume.length, 2);
      await tester.pumpWidget(const SizedBox());
      feed.dispose();
      api.close();
      store.dispose();
    },
  );
  testWidgets(
    'global visibility blocks aggregate search and explicit folders then reenable restores title',
    (tester) async {
      final prefs = await SharedPreferences.getInstance(),
          order = HomeOrder(await SharedPreferences.getInstance());
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Views')) {
            return response(
              '{"Items":[{"Id":"a","Name":"公开"},{"Id":"b","Name":"其他"}]}',
              200,
            );
          }
          final folder = request.url.queryParameters['ParentId'];
          return response(
            jsonEncode({
              'Items': [
                member(folder == 'b' ? '隐藏影片' : '可见影片', [folder ?? 'a']).data,
              ],
              'TotalRecordCount': 1,
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
        visibility: order,
      );
      Future<void> mount(String key, {MediaItem? parent}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: HomeVisibilityScope(
              order: order,
              child: Scaffold(
                body: LibraryPage(
                  key: ValueKey(key),
                  api: api,
                  browse: repo,
                  parent: parent,
                  onItem: (_) async {},
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await mount('all');
      expect(find.text('隐藏影片'), findsOneWidget);
      await order.saveHidden(api.session!, {'b'});
      await tester.pumpAndSettle();
      expect(find.text('隐藏影片'), findsNothing);
      expect(find.text('可见影片'), findsOneWidget);
      await mount('folder', parent: MediaItem({'Id': 'b', 'Name': '其他'}));
      expect(find.text('隐藏影片'), findsNothing);
      await mount('all-again');
      expect(find.text('隐藏影片'), findsNothing);
      await order.saveHidden(api.session!, {});
      await tester.pumpAndSettle();
      expect(find.text('隐藏影片'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
      order.dispose();
    },
  );
  testWidgets(
    'stale home detail and playback callbacks cannot open a hidden resource',
    (tester) async {
      final store = AppStore(await SharedPreferences.getInstance());
      final requests = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          requests.add(r.url.path);
          if (r.url.path.endsWith('/Users/synthetic-user')) {
            return response('{"Id":"synthetic-user"}', 200);
          }
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      )..session = syntheticSession();
      await store.saveSession(api.session!);
      var nativeCalls = 0;
      await tester.pumpWidget(
        YingyuApp(
          store: store,
          api: api,
          backendFactory: () {
            nativeCalls++;
            throw StateError('must not open');
          },
        ),
      );
      await settleOffline(tester);
      final home = tester.widget<HomeDashboard>(find.byType(HomeDashboard));
      final secret = member('secret', ['hidden']);
      await store.homeOrder.saveHidden(api.session!, {'hidden'});
      requests.clear();
      await home.onItem(secret);
      await home.onPlay(secret);
      await settleOffline(tester);
      expect(nativeCalls, 0);
      expect(
        requests.any(
          (p) =>
              p.contains('/Items/secret') ||
              p.contains('/Videos/') ||
              p.contains('/PlaybackInfo'),
        ),
        false,
      );
      expect(find.byType(HomeDashboard), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    },
  );
  testWidgets(
    'all server personal lists apply hidden membership before rendering',
    (tester) async {
      final store = AppStore(await SharedPreferences.getInstance());
      final secret = member('个人隐藏影片', ['hidden']),
          public = member('个人公开影片', ['public']);
      final api = EmbyClient(
        client: MockClient(
          (_) async => response(
            jsonEncode({
              'Items': [
                for (final item in [secret, public])
                  {
                    ...item.data,
                    'UserData': {'IsFavorite': true},
                  },
              ],
              'TotalRecordCount': 2,
            }),
            200,
          ),
        ),
      )..session = syntheticSession();
      await store.homeOrder.saveHidden(api.session!, {'hidden'});
      store.homeOrder.resolveMembership(
        api.session!,
        [secret, public],
        ['public', 'hidden'],
      );
      final sync = PersonalSync(api, store.personal);
      for (final list in PersonalList.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: HomeVisibilityScope(
              order: store.homeOrder,
              child: PersonalStatusPage(
                key: ValueKey(list),
                sync: sync,
                list: list,
                onItem: (_) async {},
              ),
            ),
          ),
        );
        await settleOffline(tester);
        expect(find.text('个人隐藏影片'), findsNothing);
        expect(find.text('个人公开影片'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      api.close();
      store.dispose();
    },
  );
  for (final width in [412.0, 1280.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'section visibility and order coexist width=$width $brightness',
        (tester) async {
          tester.view.physicalSize = Size(width, width == 412 ? 915 : 800);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final store = AppStore(await SharedPreferences.getInstance());
          final api = EmbyClient()..session = syntheticSession();
          final feed = HomeFeed(api, store)
            ..sections = [
              for (final name in ['动漫', '电影', '剧集'])
                HomeSection(
                  MediaItem({'Id': name, 'Name': name}),
                  loading: false,
                ),
            ];
          feed.resume = [
            member('watching', ['动漫']),
          ];
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: Scaffold(body: HomeOrderPage(feed: feed)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('home-visible-动漫')));
          await tester.pumpAndSettle();
          expect(feed.displaySections.map((s) => s.library.id), ['电影', '剧集']);
          expect(feed.orderedSections.length, 3);
          expect(feed.resume.single.id, 'watching');
          expect(
            find.byKey(const ValueKey('home-order-handle-动漫')),
            findsOneWidget,
          );
          await tester.runAsync(() async {
            final image =
                await (key.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/$appVersion-home-visibility-${width.toInt()}-${brightness.name}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          await tester.tap(find.byKey(const ValueKey('home-visible-动漫')));
          await tester.pumpAndSettle();
          expect(feed.displaySections.length, 3);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          feed.dispose();
          store.dispose();
          api.close();
        },
      );
    }
  }
}
