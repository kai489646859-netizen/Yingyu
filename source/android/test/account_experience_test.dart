import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/account_display.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/server_connection.dart';
import 'package:yingyu/core/release_notes.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/accounts.dart';
import 'package:yingyu/ui/browse_menu.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/version.dart';
import 'accounts_test.dart' show accountFixture;
import 'core_test.dart' show response;
import 'offline_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final a = accountFixture('same', name: '家庭账号'),
      b = accountFixture('same', server: 'second', name: '家庭账号');
  late AppStore store;
  late EmbyClient api;
  late List<String> calls;
  var failRequests = false, withLibraries = false;
  Completer<void>? connectionHold;
  setUp(() async {
    syntheticImagePaths();
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.saveSession(b);
    await store.saveSession(a);
    calls = [];
    failRequests = false;
    withLibraries = false;
    connectionHold = null;
    api = EmbyClient(
      client: MockClient((r) async {
        calls.add(r.url.path);
        if (r.url.path.endsWith('/Users/same')) await connectionHold?.future;
        if (failRequests) throw http.ClientException('synthetic offline');
        if (withLibraries && r.url.path.endsWith('/Views')) {
          return response(
            '{"Items":[{"Id":"movies","Name":"电影","Type":"CollectionFolder"},{"Id":"shows","Name":"动漫","Type":"CollectionFolder"}]}',
            200,
          );
        }
        if (r.url.path.endsWith('/Users/same')) {
          return response('{"Id":"same"}', 200);
        }
        if (r.url.path.endsWith('/Latest')) return response('[]', 200);
        if (r.url.queryParameters['Ids'] != null) {
          final ids = r.url.queryParameters['Ids']!.split(',');
          return response(
            jsonEncode({
              'Items': [
                for (final id in ids) {'Id': id},
              ],
              'TotalRecordCount': ids.length,
            }),
            200,
          );
        }
        return response('{"Items":[],"TotalRecordCount":0}', 200);
      }),
    );
  });
  tearDown(() {
    api.close();
    store.dispose();
  });

  test(
    'local account labels persist independently of credentials and other servers',
    () async {
      final saved = store.prefs.getString(AccountStore.storageKey);
      final other = store.accountDisplays.read(b);
      await store.saveAccountDisplay(a, '客厅原盘', 2);
      final reopened = AccountDisplays(store.prefs);
      expect(reopened.read(a).name(a), '客厅原盘');
      expect(reopened.read(a).color, 2);
      expect(reopened.read(b).name(b), '家庭账号');
      expect(reopened.read(b).color, other.color);
      expect(store.prefs.getString(AccountStore.storageKey), saved);
      expect(a.username, '家庭账号');
      expect(calls, isEmpty);
    },
  );
  test(
    'release history covers every delivered version and keeps developer details out of user copy',
    () {
      expect(releaseNotes.first.version, appVersion);
      expect(releaseNotes.last.version, '0.0.1');
      expect(
        releaseNotes.map((e) => e.version).toSet().length,
        releaseNotes.length,
      );
      final content = releaseNotes.expand((e) => e.changes).join(' ');
      expect(
        content,
        isNot(matches(r'Flutter|Dart|JNI|ABI|SHA256|ProviderIds|原子|静态|假后端')),
      );
      expect(content, isNot(contains('绝不卡顿')));
    },
  );

  Future<void> start(
    WidgetTester tester,
    Size size, {
    bool light = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await store.setTheme(light ? ThemeMode.light : ThemeMode.dark);
    await tester.pumpWidget(
      YingyuApp(
        store: store,
        api: api,
        backendFactory: () =>
            throw StateError('No native playback in these fixtures'),
      ),
    );
    await settleOffline(tester);
  }

  Future<void> accountPage(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('navigation-tab-3')));
    await settleOffline(tester);
  }

  testWidgets(
    'header avatar switches on browsing and settings pages; account keeps its own management entry',
    (tester) async {
      await start(tester, const Size(412, 915));
      for (final tab in [0, 1, 2, 3]) {
        await tester.tap(find.byKey(ValueKey('navigation-tab-$tab')));
        await settleOffline(tester);
        final avatar = find.byKey(const Key('quick-account-switch'));
        if (tab == 3) {
          expect(avatar, findsNothing);
          expect(
            find.byKey(const Key('account-avatar-switch')),
            findsOneWidget,
          );
          continue;
        }
        expect(avatar, findsOneWidget);
        if (tab == 2) {
          final before = tester.getRect(avatar);
          await tester.drag(
            find.byKey(const PageStorageKey('settings-page')),
            const Offset(0, -500),
          );
          await settleOffline(tester);
          expect(tester.getRect(avatar), before);
        }
        await tester.tap(avatar);
        await settleOffline(tester);
        expect(find.byType(AccountPicker), findsOneWidget);
        expect(find.text('当前使用'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭'));
        await settleOffline(tester);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'one banner retry replaces every home retry, preserves errors on failure and refreshes all sections once',
    (tester) async {
      await start(tester, const Size(1280, 800));
      final feed = tester
          .widget<HomeDashboard>(find.byType(HomeDashboard))
          .feed;
      feed.sections = [
        for (final entry in {'movies': '电影', 'shows': '剧集'}.entries)
          HomeSection(
            MediaItem({
              'Id': entry.key,
              'Name': entry.value,
              'Type': 'CollectionFolder',
            }),
            items: [
              MediaItem({
                'Id': '${entry.key}-cached',
                'Name': '已缓存${entry.value}',
                'Type': 'Movie',
              }),
            ],
            error: '服务器断开',
            loading: false,
          ),
      ];
      feed.resumeError = '观看记录读取失败';
      feed.error = null;
      feed.changed();
      await settleOffline(tester);
      expect(find.text('重试'), findsOneWidget);
      expect(find.textContaining('观看记录读取失败'), findsOneWidget);
      expect(find.textContaining('电影：服务器断开'), findsOneWidget);
      expect(find.textContaining('剧集：服务器断开'), findsOneWidget);
      expect(find.text('读取失败：服务器断开'), findsNothing);
      feed.error = '首页读取失败';
      api.connection.finish(
        api.connection.begin(),
        ServerStatus.disconnected,
        reason: '请检查网络',
      );
      feed.changed();
      await settleOffline(tester);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('首页读取失败'), findsOneWidget);
      expect(find.text('已缓存电影'), findsOneWidget);
      final retry = find.byKey(const Key('retry-server-connection'));
      failRequests = true;
      await tester.tap(retry);
      await settleOffline(tester);
      expect(
        find.byKey(const Key('server-connection-warning')),
        findsOneWidget,
      );
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('已缓存电影'), findsOneWidget);
      calls.clear();
      failRequests = false;
      withLibraries = true;
      connectionHold = Completer<void>();
      await tester.tap(retry);
      await tester.pump();
      await tester.tap(retry);
      await tester.pump();
      expect(calls.where((p) => p.endsWith('/Users/same')).length, 1);
      expect(find.text('重试中'), findsOneWidget);
      connectionHold!.complete();
      await settleOffline(tester);
      expect(find.byKey(const Key('server-connection-warning')), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(feed.error, isNull);
      expect(feed.resumeError, isNull);
      expect(feed.sections.every((s) => s.error == null), true);
      expect(calls.where((p) => p.endsWith('/Views')).length, 1);
      expect(calls.where((p) => p.endsWith('/Latest')).length, 2);
      expect(calls.where((p) => p.endsWith('/Resume')).length, 1);
      expect(
        calls.any((p) => p.contains('/Videos/') || p.contains('/PlaybackInfo')),
        false,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'account page owns identity, avatar opens switcher, version is above management',
    (tester) async {
      await start(tester, const Size(412, 915));
      expect(find.byKey(const Key('current-account-switch')), findsNothing);
      await accountPage(tester);
      expect(find.text('当前账号'), findsOneWidget);
      expect(find.text(a.base.toString()), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const Key('app-version-row'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const Key('manage-accounts-row'))).dy,
        ),
      );
      final versionGroup = find.ancestor(
        of: find.byKey(const Key('app-version-row')),
        matching: find.byType(SettingsGroup),
      );
      final identityGroup = find.ancestor(
        of: find.byType(AccountCard),
        matching: find.byType(SettingsGroup),
      );
      expect(
        tester.getRect(versionGroup).top,
        greaterThanOrEqualTo(tester.getRect(identityGroup).bottom),
      );
      final managementGroup = find.ancestor(
        of: find.byKey(const Key('manage-accounts-row')),
        matching: find.byType(SettingsGroup),
      );
      expect(
        tester.getRect(managementGroup).top,
        greaterThanOrEqualTo(tester.getRect(versionGroup).bottom),
      );
      await tester.tap(find.byKey(const Key('account-avatar-switch')));
      await settleOffline(tester);
      expect(
        find.byKey(ValueKey('choose-account-${accountKey(b)}')),
        findsOneWidget,
      );
      expect(find.text('当前使用'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'account appearance editor changes display but not login or source identity',
    (tester) async {
      await start(tester, const Size(412, 915));
      await accountPage(tester);
      final saved = store.prefs.getString(AccountStore.storageKey);
      await tester.tap(find.byKey(const Key('account-avatar-switch')));
      await settleOffline(tester);
      await tester.tap(find.byTooltip('管理 家庭账号').last);
      await settleOffline(tester);
      await tester.tap(find.text('备注与头像'));
      await settleOffline(tester);
      await tester.enterText(find.byKey(const Key('account-alias')), '客厅原盘');
      await tester.tap(find.byKey(const ValueKey('account-color-2')));
      await tester.tap(find.text('保存'));
      await settleOffline(tester);
      expect(
        find.descendant(
          of: find.byType(AccountPicker),
          matching: find.text('客厅原盘'),
        ),
        findsOneWidget,
      );
      expect(store.accountDisplays.read(a).alias, '客厅原盘');
      expect(store.prefs.getString(AccountStore.storageKey), saved);
      expect(calls.any((p) => p.endsWith('AuthenticateByName')), false);
      await tester.tap(find.byTooltip('关闭'));
      await settleOffline(tester);
      expect(find.text('客厅原盘'), findsOneWidget);
      expect(find.text('账号：家庭账号'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'version row opens readable current and previous release notes and copies only version',
    (tester) async {
      await start(tester, const Size(412, 915));
      await accountPage(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('app-version-row')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('account-page')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.byKey(const Key('app-version-row')));
      await settleOffline(tester);
      await tester.tap(find.byKey(const Key('app-version-row')));
      await settleOffline(tester);
      expect(find.text('更新说明'), findsOneWidget);
      expect(find.textContaining('0.7.0–0.7.9'), findsWidgets);
      expect(find.text('多个账号随时切换'), findsNothing);
      expect(find.byType(ExpansionTile), findsNWidgets(3));
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(const Key('copy-app-version')));
      await settleOffline(tester);
      expect(clipboard, '映屿安卓播放器 $appVersion');
      expect(find.byKey(const Key('toggle-release-history')), findsNothing);
      expect(displayedReleaseNotes.length, 3);
      expect(displayedReleaseNotes.map((e) => e.version), [
        appVersion,
        '0.7.9',
        '0.6.9',
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final size in [
    const Size(412, 915),
    const Size(1280, 800),
    const Size(900, 1280),
  ]) {
    testWidgets(
      'keyboard covers fixed dock while search content remains above it at $size',
      (tester) async {
        await start(tester, size);
        await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
        await settleOffline(tester);
        final before = tester.getRect(
          find.byKey(const Key('phone-navigation')),
        );
        await tester.tap(find.byKey(const Key('library-search')));
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.resetViewInsets);
        await tester.pump();
        expect(
          tester.getRect(find.byKey(const Key('phone-navigation'))),
          before,
        );
        final content = tester.getRect(
          find.byKey(const Key('main-browse-content')),
        );
        expect(content.bottom, greaterThan(size.height - 320));
        expect(
          tester.getRect(find.byKey(const Key('library-search'))).bottom,
          lessThan(size.height - 320),
        );
        expect(before.top, greaterThan(size.height - 320));
        expect(tester.takeException(), isNull);
        tester.view.resetViewInsets();
        await tester.pump();
        expect(
          tester.getRect(find.byKey(const Key('phone-navigation'))),
          before,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'large library title is the selector and current library stays visible',
    (tester) async {
      withLibraries = true;
      await start(tester, const Size(320, 640));
      await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
      await settleOffline(tester);
      final picker = find.byKey(const Key('library-picker'));
      final heading = find.widgetWithText(SectionHeading, '媒体库');
      expect(heading, findsOneWidget);
      expect(
        tester.getRect(picker).top,
        greaterThanOrEqualTo(tester.getRect(heading).top),
      );
      expect(
        find.descendant(of: heading, matching: find.text('全部')),
        findsNothing,
      );
      expect(find.text('全部媒体库'), findsNothing);
      expect(find.text('切换媒体库'), findsNothing);
      await tester.tap(picker);
      await settleOffline(tester);
      expect(find.text('切换媒体库'), findsNothing);
      await tester.binding.handlePopRoute();
      await settleOffline(tester);
      expect(find.byKey(const Key('browse-menu-panel')), findsNothing);
      expect(
        tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
        1,
      );
      expect(
        tester.getRect(picker).right,
        lessThan(
          tester.getRect(find.byKey(const Key('quick-account-switch'))).left,
        ),
      );
      await tester.tap(picker);
      await settleOffline(tester);
      final selectedAll = tester.widget<BrowseMenuChoice>(
        find.widgetWithText(BrowseMenuChoice, '全部'),
      );
      expect(selectedAll.selected, true);
      await tester.tap(find.text('动漫').hitTestable());
      await settleOffline(tester);
      expect(
        find.descendant(of: heading, matching: find.text('动漫')),
        findsOneWidget,
      );
      await tester.tap(picker);
      await settleOffline(tester);
      expect(
        tester
            .widget<BrowseMenuChoice>(
              find.widgetWithText(BrowseMenuChoice, '动漫'),
            )
            .selected,
        true,
      );
      await tester.tap(find.text('全部').hitTestable());
      await settleOffline(tester);
      await tester.tap(picker);
      await settleOffline(tester);
      await tester.tap(find.byKey(const ValueKey('navigation-tab-3')));
      await settleOffline(tester);
      expect(find.byKey(const Key('browse-menu-panel')), findsNothing);
      expect(find.text('当前账号'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
      await settleOffline(tester);
      expect(
        tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
        1,
      );
      expect(
        find.descendant(of: heading, matching: find.text('全部')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('search history is removed even with legacy enabled records', (
    tester,
  ) async {
    final key = 'yingyu.search-history.v1.${accountKey(a)}';
    const old = '{"enabled":true,"entries":["原搜索记录"]}';
    await store.prefs.setString(key, old);
    await start(tester, const Size(412, 915));
    await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
    await settleOffline(tester);
    await tester.enterText(find.byKey(const Key('library-search')), '太空漫游');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settleOffline(tester);
    await tester.tap(find.byKey(const Key('library-search')));
    await settleOffline(tester);
    expect(find.text('原搜索记录'), findsNothing);
    expect(find.byIcon(CupertinoIcons.clock), findsNothing);
    expect(find.byKey(const Key('inline-search-history')), findsNothing);
    expect(store.prefs.getString(key), old);
    await tester.tap(find.byKey(const ValueKey('navigation-tab-2')));
    await settleOffline(tester);
    expect(find.text('搜索历史'), findsNothing);
    expect(find.text('最近搜索'), findsNothing);
    expect(find.byKey(const Key('search-history-enabled')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
    await settleOffline(tester);
    final field = tester.widget<CupertinoSearchTextField>(
      find.byKey(const Key('library-search')),
    );
    expect(field.controller!.text, isEmpty);
    expect(store.prefs.getString(key), old);
    await tester.pumpWidget(const SizedBox());
  });

  group('offline experience previews', () {
    setUp(() async {
      withLibraries = true;
      await store.saveAccountDisplay(a, '客厅影院', 0);
      await store.saveAccountDisplay(b, '私人原盘', 2);
    });
    for (final spec in {
      'phone': const Size(412, 915),
      'small-phone': const Size(320, 640),
      'tablet': const Size(1280, 800),
      'tablet-portrait': const Size(900, 1280),
    }.entries) {
      for (final light in [false, true]) {
        testWidgets(
          '${spec.key} ${light ? 'light' : 'dark'} account and notes fit',
          (tester) async {
            final shadows = debugDisableShadows;
            debugDisableShadows = false;
            try {
              for (final font in {
                'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
                'packages/cupertino_icons/CupertinoIcons':
                    'packages/cupertino_icons/assets/CupertinoIcons.ttf',
              }.entries) {
                await (FontLoader(
                  font.key,
                )..addFont(rootBundle.load(font.value))).load();
              }
              final fontPath = Platform.environment['YINGYU_TEST_FONT'];
              if (fontPath != null) {
                for (final name in [
                  'Roboto',
                  '.SF UI Text',
                  '.SF UI Display',
                  'CupertinoSystemText',
                  'CupertinoSystemDisplay',
                ]) {
                  await (FontLoader(name)..addFont(
                        Future.value(
                          ByteData.sublistView(
                            File(fontPath).readAsBytesSync(),
                          ),
                        ),
                      ))
                      .load();
                }
              }
              tester.view.physicalSize = spec.value;
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              await store.setTheme(light ? ThemeMode.light : ThemeMode.dark);
              final capture = GlobalKey();
              await tester.pumpWidget(
                RepaintBoundary(
                  key: capture,
                  child: YingyuApp(
                    store: store,
                    api: api,
                    backendFactory: () => throw StateError('No native player'),
                  ),
                ),
              );
              await settleOffline(tester);
              Future<void> shot(String page) async {
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '${spec.key} $page',
                );
                await tester.runAsync(() async {
                  final picture =
                      await (capture.currentContext!.findRenderObject()
                              as RenderRepaintBoundary)
                          .toImage();
                  final png = await picture.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final file = File(
                    'build/ui-previews/$appVersion-experience-${spec.key}-${light ? 'light' : 'dark'}-$page.png',
                  );
                  await file.parent.create(recursive: true);
                  await file.writeAsBytes(png!.buffer.asUint8List());
                  picture.dispose();
                });
              }

              final feed = tester
                  .widget<HomeDashboard>(find.byType(HomeDashboard))
                  .feed;
              feed.sections = [
                HomeSection(
                  MediaItem({
                    'Id': 'preview-movies',
                    'Name': '电影',
                    'Type': 'CollectionFolder',
                  }),
                  items: [
                    for (var i = 1; i <= 8; i++)
                      MediaItem({
                        'Id': 'preview-$i',
                        'Name': '缓存影片 $i',
                        'Type': 'Movie',
                      }),
                  ],
                  error: '连接超时，已保留本机缓存',
                  loading: false,
                ),
              ];
              api.connection.finish(
                api.connection.begin(),
                ServerStatus.disconnected,
                reason: '连接超时，请检查网络与服务器',
              );
              feed.changed();
              await settleOffline(tester);
              expect(find.text('重试'), findsOneWidget);
              final title = find.text('首页').first;
              final avatar = find.byKey(const Key('quick-account-switch'));
              expect(
                (tester.getCenter(title).dy - tester.getCenter(avatar).dy)
                    .abs(),
                lessThan(1),
              );
              expect(tester.getTopRight(avatar).dx, spec.value.width - 20);
              expect(
                tester.getTopLeft(find.text('最新电影')).dx,
                closeTo(tester.getTopLeft(title).dx, .1),
              );
              expect(
                tester.getTopLeft(find.text('缓存影片 1')).dx,
                closeTo(tester.getTopLeft(title).dx, .1),
              );
              await shot('home-disconnected');
              api.connection.finish(
                api.connection.begin(),
                ServerStatus.connected,
              );
              await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
              await settleOffline(tester);
              await shot('library');
              await tester.tap(find.byKey(const Key('library-picker')));
              await settleOffline(tester);
              await shot('libraries');
              await tester.tap(find.text('动漫').hitTestable());
              await settleOffline(tester);
              await shot('library-selected');
              await accountPage(tester);
              await settleOffline(tester);
              await shot('account');
              await tester.tap(find.byKey(const Key('account-avatar-switch')));
              await settleOffline(tester);
              await shot('switcher');
              await tester.tap(find.byTooltip('关闭'));
              await settleOffline(tester);
              await tester.scrollUntilVisible(
                find.byKey(const Key('app-version-row')),
                200,
                scrollable: find
                    .descendant(
                      of: find.byKey(const PageStorageKey('account-page')),
                      matching: find.byType(Scrollable),
                    )
                    .first,
              );
              await tester.ensureVisible(
                find.byKey(const Key('app-version-row')),
              );
              await settleOffline(tester);
              await tester.tap(find.byKey(const Key('app-version-row')));
              await settleOffline(tester);
              await shot('updates');
              await tester.pumpWidget(const SizedBox());
            } finally {
              debugDisableShadows = shadows;
            }
          },
        );
      }
    }
  });
}
