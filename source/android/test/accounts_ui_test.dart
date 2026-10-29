import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/account_controller.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/ui/accounts.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'accounts_test.dart' show accountFixture;
import 'core_test.dart' show response, playbackData;
import 'offline_settle.dart';
import 'playback_test.dart' show FakeBackend;

void main() {
  late AppStore store;
  late EmbyClient api;
  late List<http.Request> calls;
  late FakeBackend backend;
  var bStatus = 200;
  final a = accountFixture('a', name: '映屿 · 日常'),
      b = accountFixture('b', server: 'cinema', name: '映屿 · 原盘');
  Json movie(String user) => {
    'Id': 'same-id',
    'Name': '$user 的影片',
    'Type': 'Movie',
    'RunTimeTicks': 54000000000,
    'ProviderIds': {'Tmdb': '550'},
    'UserData': {'PlaybackPositionTicks': 0},
  };
  setUp(() async {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.saveSession(b);
    await store.saveSession(a);
    backend = FakeBackend()..gate.complete();
    calls = [];
    bStatus = 200;
    api = EmbyClient(
      client: MockClient((r) async {
        calls.add(r);
        final user = r.headers['X-Emby-Token'] == b.token ? 'b' : 'a';
        if (r.url.path.endsWith('/Users/$user')) {
          return response(
            jsonEncode({'Id': user}),
            user == 'b' ? bStatus : 200,
          );
        }
        if (r.url.path.endsWith('/Latest')) return response('[]', 200);
        if (r.url.path.endsWith('/Views') || r.url.path.endsWith('/Resume')) {
          return response('{"Items":[]}', 200);
        }
        if (r.url.path.endsWith('/Items')) {
          return response(
            jsonEncode({
              'Items': [movie(user)],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }
        if (r.url.path.endsWith('/PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (r.url.path.contains('/Sessions/Playing')) return response('', 204);
        return response(jsonEncode(movie(user)), 200);
      }),
    );
  });
  tearDown(() {
    api.close();
    store.dispose();
  });

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      YingyuApp(store: store, api: api, backendFactory: () => backend),
    );
    await settleOffline(tester);
  }

  Future<void> library(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('navigation-tab-1')));
    await settleOffline(tester);
  }

  testWidgets(
    'avatar shortcut switches identity and catalogue together; old resource cannot remain under new account',
    (tester) async {
      await start(tester);
      await library(tester);
      expect(find.text('a 的影片'), findsOneWidget);
      await tester.tap(find.byKey(const Key('quick-account-switch')));
      await settleOffline(tester);
      expect(find.text('当前使用'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('choose-account-${accountKey(b)}')));
      await settleOffline(tester);
      expect(
        tester
            .widget<AccountAvatar>(find.byType(AccountAvatar).first)
            .account
            .userId,
        b.userId,
      );
      await tester.tap(find.byKey(const ValueKey('navigation-tab-3')));
      await settleOffline(tester);
      expect(find.text('映屿 · 原盘'), findsOneWidget);
      expect(find.text('a 的影片'), findsNothing);
      await library(tester);
      expect(find.text('b 的影片'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleOffline(tester);
      expect(find.text('a 的影片'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'explicit logout can be cancelled and then enters the remaining account without a picker',
    (tester) async {
      await tester.runAsync(() async {
        await store.saveProgress(a, 'same-id', const Duration(minutes: 3));
        await store.saveProgress(b, 'same-id', const Duration(minutes: 8));
      });
      await start(tester);
      await tester.tap(find.byKey(const ValueKey('navigation-tab-3')));
      await settleOffline(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('logout-current-account')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('account-page')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(
        find.byKey(const Key('logout-current-account')),
      );
      await settleOffline(tester);
      await tester.tap(find.byKey(const Key('logout-current-account')));
      await settleOffline(tester);
      expect(
        find.textContaining(a.base.toString()).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.text('取消'));
      await settleOffline(tester);
      expect(store.accounts.selected!.id, accountKey(a));
      expect(calls.where((r) => r.url.path.endsWith('/Logout')), isEmpty);
      await tester.scrollUntilVisible(
        find.byKey(const Key('logout-current-account')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('account-page')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(
        find.byKey(const Key('logout-current-account')),
      );
      await settleOffline(tester);
      await tester.tap(find.byKey(const Key('logout-current-account')));
      await settleOffline(tester);
      await tester.tap(find.text('退出登录'));
      await settleOffline(tester);
      expect(store.accounts.selected!.id, accountKey(b));
      expect(store.accounts.accounts.map((e) => e.id), [accountKey(b)]);
      expect(store.localProgress(a, 'same-id'), const Duration(minutes: 3));
      expect(store.localProgress(b, 'same-id'), const Duration(minutes: 8));
      final logoutCalls = calls
          .where((r) => r.url.path.endsWith('/Logout'))
          .toList();
      expect(logoutCalls.length, 1);
      expect(logoutCalls.single.headers['X-Emby-Token'], a.token);
      expect(find.text('选择或管理账号'), findsNothing);
      expect(find.byKey(const Key('quick-account-switch')), findsOneWidget);
      await library(tester);
      expect(find.text('b 的影片'), findsOneWidget);
      expect(find.text('a 的影片'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'failed switch preserves A and cancel adding requires no login or logout request',
    (tester) async {
      await start(tester);
      await library(tester);
      bStatus = 500;
      await tester.tap(find.byKey(const Key('quick-account-switch')));
      await settleOffline(tester);
      await tester.tap(find.byKey(ValueKey('choose-account-${accountKey(b)}')));
      await settleOffline(tester);
      expect(find.textContaining('服务器请求失败'), findsOneWidget);
      expect(store.accounts.selected!.id, accountKey(a));
      await tester.tap(find.byKey(const Key('add-account')));
      await settleOffline(tester);
      await tester.enterText(
        find.byKey(const Key('account-username')),
        'unfinished',
      );
      await tester.binding.handlePopRoute();
      await settleOffline(tester);
      await tester.tap(find.byTooltip('关闭'));
      await settleOffline(tester);
      expect(find.text('a 的影片'), findsOneWidget);
      expect(
        calls.any(
          (r) =>
              r.url.path.endsWith('/AuthenticateByName') ||
              r.url.path.endsWith('/Logout'),
        ),
        false,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    '401 is attached to target and relogin locks that account identity',
    (tester) async {
      await start(tester);
      bStatus = 401;
      await tester.tap(find.byKey(const Key('quick-account-switch')));
      await settleOffline(tester);
      await tester.tap(find.byKey(ValueKey('choose-account-${accountKey(b)}')));
      await settleOffline(tester);
      expect(find.text('登录已过期 · 点击重新登录'), findsOneWidget);
      expect(store.accounts.selected!.id, accountKey(a));
      await tester.tap(find.byKey(ValueKey('choose-account-${accountKey(b)}')));
      await settleOffline(tester);
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('account-server')),
                matching: find.byType(EditableText),
              ),
            )
            .readOnly,
        true,
      );
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: find.byKey(const Key('account-username')),
                matching: find.byType(EditableText),
              ),
            )
            .readOnly,
        true,
      );
      expect(find.text(b.base.host), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byKey(const Key('server-port'))).readOnly,
        true,
      );
      expect(
        tester.widget<TextField>(find.byKey(const Key('server-path'))).readOnly,
        true,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'same movie ID after switching opens and reports only B source through fake backend',
    (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        Device.channel,
        (call) async => call.method == 'playbackNetwork'
            ? 'unmetered'
            : call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(Device.channel, null),
      );
      await start(tester);
      await tester.tap(find.byKey(const Key('quick-account-switch')));
      await settleOffline(tester);
      await tester.tap(find.byKey(ValueKey('choose-account-${accountKey(b)}')));
      await settleOffline(tester);
      await library(tester);
      await tester.tap(find.text('b 的影片'));
      await settleOffline(tester);
      await tester.tap(find.text('播放'));
      await settleOffline(tester);
      final url = Uri.parse(backend.receivedRoute!.url);
      expect(url.host, b.base.host);
      expect(url.queryParameters['api_key'], b.token);
      expect(find.byKey(const Key('player-account-label')), findsOneWidget);
      final reports = calls.where(
        (r) => r.url.path.contains('/Sessions/Playing'),
      );
      expect(reports, isNotEmpty);
      expect(
        reports.every(
          (r) =>
              r.url.host == b.base.host && r.headers['X-Emby-Token'] == b.token,
        ),
        true,
      );
      await tester.tap(find.byTooltip('退出播放'));
      await settleOffline(tester);
      await tester.pumpWidget(const SizedBox());
    },
  );

  group('account picker previews', () {
    setUp(() async {
      await store.saveSession(
        accountFixture('family', server: 'family', name: '家庭影院'),
      );
      await store.saveSession(a);
      await store.accounts.expire(accountKey(b));
    });
    for (final spec in {
      'phone': const Size(412, 915),
      'small-phone': const Size(320, 640),
      'phone-landscape': const Size(844, 390),
      'tablet': const Size(1280, 800),
    }.entries) {
      for (final light in [false, true]) {
        testWidgets(
          'account picker ${spec.key} ${light ? 'light' : 'dark'} fits and renders',
          (tester) async {
            tester.view.physicalSize = spec.value;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);

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
                        ByteData.sublistView(File(fontPath).readAsBytesSync()),
                      ),
                    ))
                    .load();
              }
            }

            final controller = AccountController(store, api);
            api.session = a;
            controller.api = api;
            controller.connected = true;
            final capture = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: capture,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: appTheme(light ? Brightness.light : Brightness.dark),
                  home: Scaffold(body: AccountPicker(controller: controller)),
                ),
              ),
            );
            await settleOffline(tester);

            expect(tester.takeException(), isNull);
            final rect = tester.getRect(
              find.byKey(const Key('account-picker')),
            );
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(spec.value.height));
            expect(find.text('当前使用'), findsOneWidget);
            await tester.runAsync(() async {
              final img =
                  await (capture.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await img.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/ui-previews/$appVersion-accounts-${spec.key}-${light ? 'light' : 'dark'}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              img.dispose();
            });
            await tester.pumpWidget(const SizedBox());
            controller.dispose();
          },
        );
      }
    }
  });
  testWidgets(
    'aggregate B result switches account then opens B detail exactly once',
    (tester) async {
      await start(tester);
      await library(tester);
      await tester.tap(find.byKey(const Key('open-federated-search')));
      await settleOffline(tester);
      await tester.enterText(find.byKey(const Key('federated-search')), '影片');
      await tester.pump(const Duration(milliseconds: 400));
      await settleOffline(tester);
      await tester.ensureVisible(find.text('b 的影片'));
      await tester.tap(find.text('b 的影片'));
      await settleOffline(tester);
      expect(store.accounts.selected!.id, accountKey(b));
      expect(find.byType(DetailPage), findsOneWidget);
      expect(
        tester.widget<DetailPage>(find.byType(DetailPage)).api.session!.userId,
        b.userId,
      );
      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await settleOffline(tester);
      store.notifyListeners();
      await settleOffline(tester);
      expect(find.byType(DetailPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await settleOffline(tester);
    },
  );
}
