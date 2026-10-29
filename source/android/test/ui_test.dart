import 'offline_settle.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/login.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;

final sampleItems = List.generate(
  60,
  (i) => {
    'Id': 'movie-$i',
    'Name': '合成影片 ${i + 1}',
    'Type': i == 1 ? 'Series' : 'Movie',
    'ProductionYear': 2026,
    'RunTimeTicks': 54000000000,
    'Overview': '用于隔离界面验证的合成影视介绍。来自独立测试数据，不连接真实媒体库。',
    'CommunityRating': 8.5,
    'UserData': {'PlaybackPositionTicks': i == 0 ? 350000000 : 0},
  },
);

void main() {
  setUp(() {
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  EmbyClient fixture() => EmbyClient(
    client: MockClient((req) async {
      if (req.url.path.endsWith('/Users/synthetic-user')) {
        return response('{"Id":"synthetic-user"}', 200);
      }
      if (req.url.path.endsWith('/Latest')) return response('[]', 200);
      if (req.url.path.endsWith('/Resume')) {
        return response('{"Items":[]}', 200);
      }
      if (req.url.path.endsWith('/Views')) {
        return response(
          jsonEncode({
            'Items': [
              {'Id': 'lib', 'Name': '电影', 'IsFolder': true},
            ],
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/Items')) {
        final offset =
            int.tryParse(req.url.queryParameters['StartIndex'] ?? '') ?? 0;
        final search = req.url.queryParameters['SearchTerm'];
        final items = search == null
            ? sampleItems.skip(offset).take(48).toList()
            : sampleItems
                  .where((i) => '${i['Name']}'.contains(search))
                  .toList();
        return response(
          jsonEncode({
            'Items': items,
            'TotalRecordCount': search == null ? 60 : items.length,
          }),
          200,
        );
      }
      if (req.url.path.endsWith('/Seasons')) {
        return response('{"Items":[{"Id":"season","Name":"第一季"}]}', 200);
      }
      if (req.url.path.endsWith('/Episodes')) {
        return response(
          '{"Items":[{"Id":"episode","Name":"第一集","Type":"Episode"}],"TotalRecordCount":1}',
          200,
        );
      }
      return response(jsonEncode(sampleItems.first), 200);
    }),
  )..session = syntheticSession();

  Future<void> size(WidgetTester tester, Size value) async {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final spec in <String, Size>{
    'phone-portrait': const Size(412, 915),
    'phone-landscape': const Size(915, 412),
    'tablet-portrait': const Size(900, 1280),
    'tablet-landscape': const Size(1280, 800),
  }.entries) {
    testWidgets('${spec.key}: login, navigation, media detail and theme fit', (
      tester,
    ) async {
      await size(tester, spec.value);
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = fixture();
      await store.saveSession(api.session!);
      await tester.pumpWidget(
        YingyuApp(
          store: store,
          api: api,
          backendFactory: () =>
              throw StateError('Native player forbidden in UI test'),
        ),
      );
      await settleOffline(tester);
      final navigation = find.byKey(const Key('phone-navigation'));
      expect(navigation, findsOneWidget);
      final dock = tester.getRect(navigation);
      expect(dock.bottom, closeTo(spec.value.height - 6, .1));
      expect(dock.height, 68);
      if (spec.value.width > spec.value.height) {
        expect(find.byType(AppBar), findsNothing);
        final content = tester.getRect(
          find.byKey(const Key('main-swipe-pages')),
        );
        expect(content.bottom, lessThanOrEqualTo(dock.top - 6));
      }
      await tester.tap(find.text('媒体库').hitTestable().last);
      await settleOffline(tester);
      expect(find.text('合成影片 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final homeBoundary = tester.renderObject<RenderObject>(
        find.byType(HomePage),
      );
      expect(homeBoundary.attached, true);
      await tester.tap(find.text('账户').hitTestable().last);
      await settleOffline(tester);
      await tester.scrollUntilVisible(
        find.text(appVersion),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('account-page')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text(appVersion), findsOneWidget);
      await tester.tap(find.text('设置').hitTestable().last);
      await settleOffline(tester);
      await tester.scrollUntilVisible(
        find.text('浅色'),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('settings-page')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await settleOffline(tester);
      await tester.tap(find.text('浅色'));
      await settleOffline(tester);
      expect(store.theme, ThemeMode.light);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('媒体库').hitTestable().last);
      await settleOffline(tester);
      await tester.ensureVisible(find.text('合成影片 1'));
      await settleOffline(tester);
      await tester.tap(find.text('合成影片 1'));
      await settleOffline(tester);
      expect(find.text('从头播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    });
  }
  testWidgets(
    'complete catalogue search returns empty results without another metadata load',
    (tester) async {
      await size(tester, const Size(412, 915));
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = fixture();
      await store.saveSession(api.session!);
      await tester.pumpWidget(YingyuApp(store: store, api: api));
      await settleOffline(tester);
      await tester.tap(find.text('媒体库').hitTestable().last);
      await settleOffline(tester);
      await tester.enterText(find.byType(EditableText), '不存在');
      await tester.pump(const Duration(milliseconds: 450));
      await settleOffline(tester);
      expect(find.text('没有匹配的影片或剧集，演员结果见上方'), findsOneWidget);
      expect(find.text('已显示全部'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    },
  );
  testWidgets(
    'home search opens a separate global search and returns to the original home tab',
    (tester) async {
      await size(tester, const Size(412, 915));
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = fixture();
      await store.saveSession(api.session!);
      await tester.pumpWidget(YingyuApp(store: store, api: api));
      await settleOffline(tester);
      await tester.tap(find.byKey(const Key('home-search')));
      await settleOffline(tester);
      expect(find.byKey(const Key('search-back')), findsOneWidget);
      await tester.enterText(find.byType(EditableText), '合成影片 1');
      await tester.pump(const Duration(milliseconds: 250));
      await settleOffline(tester);
      expect(find.text('合成影片 1'), findsWidgets);
      await tester.binding.handlePopRoute();
      await settleOffline(tester);
      expect(find.byKey(const Key('home-search')), findsOneWidget);
      expect(
        tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
        0,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    },
  );
  testWidgets(
    'compact login with keyboard inset and large text does not overflow',
    (tester) async {
      await size(tester, const Size(740, 360));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(740, 360),
              viewInsets: EdgeInsets.only(bottom: 160),
              textScaler: TextScaler.linear(1.4),
            ),
            child: LoginPage(login: (_, _, _) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('tablet rotation keeps search text, selected page and results', (
    tester,
  ) async {
    await size(tester, const Size(900, 1280));
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(await SharedPreferences.getInstance());
    final api = fixture();
    await store.saveSession(api.session!);
    await tester.pumpWidget(YingyuApp(store: store, api: api));
    await settleOffline(tester);
    await tester.tap(find.text('媒体库').hitTestable().last);
    await settleOffline(tester);
    await tester.enterText(find.byType(EditableText), '合成影片 1');
    await tester.pump(const Duration(milliseconds: 450));
    await settleOffline(tester);
    tester.view.physicalSize = const Size(1280, 800);
    await settleOffline(tester);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '合成影片 1',
    );
    expect(find.text('合成影片 1'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('账户').hitTestable().last);
    await settleOffline(tester);
    tester.view.physicalSize = const Size(900, 1280);
    await settleOffline(tester);
    expect(find.text(appVersion), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    api.close();
    store.dispose();
  });
  testWidgets(
    'narrow phone with enlarged text keeps library, detail and account usable',
    (tester) async {
      await size(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = fixture();
      await store.saveSession(api.session!);
      await tester.pumpWidget(YingyuApp(store: store, api: api));
      await settleOffline(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('媒体库').hitTestable().last);
      await settleOffline(tester);
      await tester.tap(find.text('合成影片 1'));
      await settleOffline(tester);
      await tester.ensureVisible(find.text('从头播放'));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭'));
      await settleOffline(tester);
      await tester.tap(find.text('账户').hitTestable().last);
      await settleOffline(tester);
      await tester.tap(find.text('设置').hitTestable().last);
      await settleOffline(tester);
      await tester.ensureVisible(find.text('浅色'));
      await settleOffline(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    },
  );
  testWidgets('isolated synthetic previews', (tester) async {
    for (final font in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      final loader = FontLoader(font.key)..addFont(rootBundle.load(font.value));
      await loader.load();
    }
    final fontPath = Platform.environment['YINGYU_TEST_FONT'];
    if (fontPath != null) {
      final loader = FontLoader('Roboto')
        ..addFont(
          Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())),
        );
      await loader.load();
    }
    for (final spec in <String, Size>{
      'phone': const Size(412, 915),
      'tablet': const Size(1280, 800),
    }.entries) {
      await size(tester, spec.value);
      final key = GlobalKey();
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = fixture();
      await store.saveSession(api.session!);
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: YingyuApp(store: store, api: api),
        ),
      );
      await settleOffline(tester);
      Future<void> capture(String name) async {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/ui-previews/$name.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.tap(find.text('媒体库').hitTestable().last);
      await settleOffline(tester);
      await capture('${spec.key}-library');
      await tester.tap(find.text('合成影片 1'));
      await settleOffline(tester);
      await capture('${spec.key}-detail');
      await tester.pumpWidget(const SizedBox());
      api.close();
      store.dispose();
    }
  });
}
