import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/account_controller.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/log_export.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/offline_translation.dart';
import 'package:yingyu/ui/accounts.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/logs.dart';
import 'package:yingyu/ui/offline_translation.dart';
import 'package:yingyu/ui/style.dart';
import 'accounts_test.dart' show accountFixture;
import 'core_test.dart' show response, syntheticSession;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'adaptive_072_test.dart' show capture;
import 'offline_settle.dart';
import 'offline_translation_test.dart' show FakeTranslation;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    syntheticImagePaths();
  });
  test(
    'account reorder persists exact objects, selection and expiration without network',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      final a = accountFixture('one'),
          b = accountFixture('two'),
          c = accountFixture('three');
      await store.saveSession(a);
      await store.saveSession(b);
      await store.saveSession(c);
      await store.accounts.expire(accountKey(b));
      final transport = EmbyClient(
        client: MockClient(
          (_) async => throw StateError('No network for ordering'),
        ),
      );
      final controller = AccountController(store, transport);
      await controller.reorder([accountKey(c), accountKey(a), accountKey(b)]);
      expect(controller.accounts.map((a) => a.session.userId), [
        'three',
        'one',
        'two',
      ]);
      expect(controller.accounts.last.needsLogin, true);
      expect(store.accounts.selected!.session.userId, 'three');
      final reopened = AppStore(prefs);
      await reopened.loadSession();
      expect(
        reopened.accounts.accounts.map((a) => a.id),
        controller.accounts.map((a) => a.id),
      );
      await expectLater(
        controller.reorder([accountKey(a), accountKey(a), accountKey(c)]),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.accounts.first.session.userId, 'three');
      controller.dispose();
      transport.close();
      store.dispose();
      reopened.dispose();
    },
  );
  for (final size in [const Size(320, 700), const Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'account drag order is saved and quick switch reads it $size $brightness',
        (tester) async {
          setDisplay(tester, size);
          final store = AppStore(await SharedPreferences.getInstance());
          for (final id in ['A', 'B', 'C']) {
            await store.saveSession(accountFixture(id, name: '账号 $id'));
          }
          final api = EmbyClient(
            client: MockClient(
              (_) async => throw StateError('Ordering must be local'),
            ),
          );
          final controller = AccountController(store, api);
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                theme: appTheme(brightness),
                home: Scaffold(
                  body: AccountPicker(
                    controller: controller,
                    allowReorder: true,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('account-order')));
          await tester.pumpAndSettle();
          final handles = find.byType(ReorderableDragStartListener);
          final first = tester.getCenter(handles.first),
              last = tester.getCenter(handles.last);
          final gesture = await tester.startGesture(last);
          await tester.pump();
          await gesture.moveBy(const Offset(0, -30));
          await tester.pump();
          await gesture.moveTo(first + const Offset(0, 2));
          await tester.pump(const Duration(milliseconds: 400));
          await capture(
            tester,
            key,
            '074-account-drag-${size.width.toInt()}-${brightness.name}',
          );
          await gesture.up();
          await tester.pumpAndSettle();
          await tester.tap(find.text('完成'));
          await tester.pumpAndSettle();
          expect(controller.accounts.map((a) => a.session.userId), [
            'C',
            'A',
            'B',
          ]);
          await capture(
            tester,
            key,
            '073-account-${size.width.toInt()}-${brightness.name}',
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness),
              home: Scaffold(
                body: AccountPicker(
                  key: const Key('quick'),
                  controller: controller,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('account-order')), findsNothing);
          expect(
            tester.getTopLeft(find.text('账号 C')).dy,
            lessThan(tester.getTopLeft(find.text('账号 A')).dy),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          controller.dispose();
          api.close();
          store.dispose();
        },
      );
    }
    testWidgets(
      '500 variable log rows keep exact scroll extent and snapshot at $size',
      (tester) async {
        setDisplay(tester, size);
        final log = DiagnosticLog();
        for (var i = 0; i < 1100; i++) {
          log.add(LogArea.player, '记录 $i ${'原画读取说明' * (i % 7 * 11)}');
        }
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: LogsPage(log: log),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final view = tester.widget<CustomScrollView>(
          find.byType(CustomScrollView),
        );
        final scroll = view.controller!;
        final extent = scroll.position.maxScrollExtent;
        expect(extent, greaterThan(10000));
        for (final fraction in [.2, .5, .8, .95]) {
          scroll.jumpTo(extent * fraction);
          await tester.pumpAndSettle();
          expect(scroll.position.maxScrollExtent, closeTo(extent, .01));
          expect(tester.takeException(), isNull);
        }
        final offset = scroll.offset;
        log.add(LogArea.player, '新日志不挤动正在阅读的旧记录');
        await tester.pumpAndSettle();
        expect(scroll.offset, offset);
        expect(scroll.position.maxScrollExtent, closeTo(extent, .01));
        expect(
          tester
              .widget<SliverVariedExtentList>(
                find.byType(SliverVariedExtentList),
              )
              .delegate
              .estimatedChildCount,
          999,
        );
        expect(LogExportSnapshot(log).lines.length, 1101);
        await capture(tester, key, '073-log-${size.width.toInt()}');
        scroll.jumpTo(0);
        await tester.pumpAndSettle();
        expect(find.text('新日志不挤动正在阅读的旧记录'), findsOneWidget);
        await tester.tap(find.text('选择日志'));
        await tester.pumpAndSettle();
        scroll.jumpTo(scroll.position.maxScrollExtent * .5);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        log.dispose();
      },
    );
    testWidgets('detail return keeps query results and offset at $size', (
      tester,
    ) async {
      setDisplay(tester, size);
      final prefs = await SharedPreferences.getInstance();
      var requests = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          requests++;
          if (r.url.path.endsWith('/Views')) {
            return response('{"Items":[]}', 200);
          }
          return response(
            jsonEncode({
              'Items': List.generate(
                64,
                (i) => {
                  'Id': 'm$i',
                  'Name': '${i < 48 ? '匹配影片' : '其他影片'} $i',
                  'Type': 'Movie',
                },
              ),
              'TotalRecordCount': 64,
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
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: LibraryPage(
              api: api,
              browse: repo,
              searchMode: true,
              onItem: (_) async {
                await nav.currentState!.push(
                  MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('回到结果'),
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
      await tester.enterText(find.byType(CupertinoSearchTextField), '匹配影片');
      await tester.pump(const Duration(milliseconds: 600));
      await settleOffline(tester);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(550);
      await settleOffline(tester);
      final before = scroll.offset;
      final calls = requests;
      await tester.tap(find.textContaining('匹配影片 ').hitTestable().first);
      await settleOffline(tester);
      await tester.tap(find.text('回到结果'));
      await settleOffline(tester);
      expect(
        tester
            .widget<CupertinoSearchTextField>(
              find.byType(CupertinoSearchTextField),
            )
            .controller!
            .text,
        '匹配影片',
      );
      expect(scroll.offset, closeTo(before, .01));
      expect(requests, calls);
      expect(find.textContaining('其他影片 ').hitTestable(), findsNothing);
      expect(tester.testTextInput.isVisible, false);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
    });
  }
  testWidgets(
    'offline model bar shows waiting and download, disappears on completion',
    (tester) async {
      setDisplay(tester, const Size(320, 700));
      final preview = GlobalKey();
      final native = FakeTranslation()
        ..value = const TranslationStatus(phase: 'waiting_wifi');
      final service = OfflineTranslation(
        await SharedPreferences.getInstance(),
        platform: native,
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: preview,
          child: MaterialApp(
            theme: appTheme(Brightness.dark),
            home: Scaffold(
              body: SingleChildScrollView(
                child: OfflineTranslationGroup(service: service),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      LinearProgressIndicator bar() =>
          tester.widget(find.byKey(const Key('translation-download-progress')));
      expect(bar().value, 0);
      await capture(tester, preview, '073-translation-waiting');
      native.value = const TranslationStatus(phase: 'downloading');
      await service.refresh();
      await tester.pump(const Duration(milliseconds: 100));
      expect(bar().value, isNull);
      await capture(tester, preview, '073-translation-downloading');
      native.value = const TranslationStatus(phase: 'waiting_network');
      await service.refresh();
      await tester.pump(const Duration(milliseconds: 100));
      expect(bar().value, 0);
      native.value = const TranslationStatus(ready: true);
      await service.refresh();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translation-download-progress')),
        findsNothing,
      );
      await capture(tester, preview, '073-translation-ready');
      for (final phase in ['deleting', 'error', 'pending']) {
        native.value = TranslationStatus(phase: phase);
        await service.refresh();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          find.byKey(const Key('translation-download-progress')),
          findsNothing,
        );
      }
      expect(native.downloads, 0);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
    },
  );
}
