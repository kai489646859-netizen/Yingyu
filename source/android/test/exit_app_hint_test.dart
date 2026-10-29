import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'offline_settle.dart';
import 'offline_capture.dart';
import 'scroll_affordance_test.dart' show fonts;

void main() {
  late AppStore store;
  late EmbyClient api;
  var exits = 0;
  late GlobalKey capture;
  setUp(() async {
    syntheticImagePaths();
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    api = EmbyClient(
      client: MockClient(
        (request) async => response(
          request.url.path.endsWith('/Latest') ? '[]' : '{"Items":[]}',
          200,
        ),
      ),
    )..session = syntheticSession();
    await store.saveSession(api.session!);
    exits = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') exits++;
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    api.close();
    store.dispose();
  });
  Future<void> start(WidgetTester tester, Size size) async {
    await fonts();
    capture = GlobalKey();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: HomePage(
            api: api,
            store: store,
            createBackend: () =>
                throw StateError('No native backend in this test'),
            logout: () async => throw StateError('Exiting must not log out'),
          ),
        ),
      ),
    );
    await settleOffline(tester);
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
  }

  Future<void> tab(WidgetTester tester, int index) async {
    await tester.tap(find.byKey(ValueKey('navigation-tab-$index')));
    await settleOffline(tester);
  }

  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    for (var index = 0; index < 4; index++) {
      testWidgets(
        'root $index shows bottom hint, expires and exits on repeat at $size',
        (tester) async {
          await start(tester, size);
          await tab(tester, index);
          final prefsBefore = store.prefs.getString('yingyu.accounts.v1');
          expect(prefsBefore, isNotNull);
          await back(tester);
          expect(exits, 0);
          expect(
            tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
            index,
          );
          final hint = find.byKey(const Key('exit-app-hint'));
          expect(find.text('再按一次退出 app'), findsOneWidget);
          final rect = tester.getRect(hint);
          expect(rect.top, greaterThan(size.height * .6));
          expect(rect.bottom, lessThan(size.height));
          if (index == 0) {
            await captureOffline(
              tester,
              capture,
              'exit-hint-${size.width.toInt()}',
            );
          }
          await tester.pump(const Duration(milliseconds: 2100));
          expect(hint, findsNothing);
          await back(tester);
          expect(exits, 0);
          await tester.pump(const Duration(milliseconds: 300));
          await back(tester);
          expect(exits, 1);
          expect(hint, findsNothing);
          expect(api.session, isNotNull);
          expect(store.prefs.getString('yingyu.accounts.v1'), prefsBefore);
          await tester.pumpWidget(const SizedBox());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('page switch, modal and background reset the exit confirmation', (
    tester,
  ) async {
    await start(tester, const Size(412, 915));
    await back(tester);
    await tab(tester, 3);
    expect(find.text('再按一次退出 app'), findsNothing);
    await back(tester);
    await tester.tap(find.byKey(const Key('app-version-row')));
    await settleOffline(tester);
    expect(find.text('更新说明'), findsOneWidget);
    await back(tester);
    await settleOffline(tester);
    expect(find.text('再按一次退出 app'), findsNothing);
    expect(exits, 0);
    await back(tester);
    expect(exits, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('再按一次退出 app'), findsNothing);
    await back(tester);
    expect(exits, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('catalogue menu and keyboard consume Back before exit', (
    tester,
  ) async {
    await start(tester, const Size(412, 915));
    await tab(tester, 1);
    await tester.tap(find.byKey(const Key('library-sort')));
    await settleOffline(tester);
    expect(find.byKey(const Key('browse-menu-panel')), findsOneWidget);
    await back(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('browse-menu-panel')), findsNothing);
    expect(find.text('再按一次退出 app'), findsNothing);
    await tester.tap(find.byKey(const Key('library-search')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pump();
    await back(tester);
    expect(find.text('再按一次退出 app'), findsNothing);
    expect(exits, 0);
    tester.view.resetViewInsets();
    await tester.pumpWidget(const SizedBox());
  });
}
