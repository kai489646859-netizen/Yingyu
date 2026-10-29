import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/account_avatars.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/log_export.dart';
import 'package:yingyu/core/log_storage.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/anchored_menu.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/logs.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/ui/expansion_chevron.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;

Future<void> capture(WidgetTester tester, GlobalKey key, String name) async {
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/ui-previews/$appVersion-adaptive-$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(fonts);
  for (final size in [const Size(320, 700), const Size(1280, 800)]) {
    for (final scale in [1.0, 1.7]) {
      for (final bottom in [false, true]) {
        testWidgets('settings panel fits $size scale $scale bottom $bottom', (
          tester,
        ) async {
          setDisplay(tester, size);
          final key = GlobalKey();
          String? selected;
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                theme: appTheme(Brightness.dark),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Align(
                    alignment: bottom
                        ? Alignment.bottomCenter
                        : Alignment.topCenter,
                    child: SizedBox(
                      height: 110,
                      child: SettingsChoice<String>(
                        id: 'fixture',
                        title: '主题色',
                        subtitle: '青绿',
                        value: 'teal',
                        choices: const {
                          'teal': '青绿',
                          'blue': '海蓝',
                          'rose': '玫红',
                        },
                        onChanged: (value) => selected = value,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.byKey(const Key('fixture')));
          await tester.pumpAndSettle();
          final panel = tester.getRect(
            find.byKey(const Key('anchored-menu-panel')),
          );
          final anchor = tester.getRect(find.byKey(const Key('fixture-arrow')));
          final chevron = tester.widget<ExpansionChevron>(
            find.byType(ExpansionChevron),
          );
          expect(chevron.expanded, true);
          expect(chevron.opensUp, bottom);
          expect(
            tester
                .widget<AnimatedRotation>(find.byType(AnimatedRotation))
                .turns,
            bottom ? -.25 : .25,
          );
          if (bottom) {
            expect(panel.bottom, lessThanOrEqualTo(anchor.top + .01));
          } else {
            expect(panel.top, closeTo(anchor.bottom, .01));
          }
          expect(panel.left, greaterThanOrEqualTo(8));
          expect(panel.right, lessThanOrEqualTo(size.width - 8));
          expect(panel.height, greaterThanOrEqualTo(152));
          expect(panel.width, lessThan(size.width * .65));
          await capture(tester, key, '${size.width.toInt()}-$scale-$bottom');
          await tester.tap(find.text('海蓝'));
          await tester.pumpAndSettle();
          expect(selected, 'blue');
          expect(find.byKey(const Key('anchored-menu-panel')), findsNothing);
          expect(
            tester
                .widget<ExpansionChevron>(find.byType(ExpansionChevron))
                .expanded,
            false,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  testWidgets(
    'long popup remains scrollable above a bottom trigger and dismisses outside',
    (tester) async {
      setDisplay(tester, const Size(360, 640));
      var selected = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: AnchoredMenuButton<int>(
                id: 'long',
                label: '长列表',
                menuWidth: 160,
                items: (_) => [
                  for (var i = 0; i < 40; i++)
                    PopupMenuItem(value: i, child: Text('选项 $i')),
                ],
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('long')));
      await tester.pumpAndSettle();
      final panel = tester.getRect(
        find.byKey(const Key('anchored-menu-panel')),
      );
      expect(panel.bottom, lessThanOrEqualTo(596));
      expect(panel.top, greaterThanOrEqualTo(8));
      await tester.scrollUntilVisible(find.text('选项 39'), 300);
      await tester.tap(find.text('选项 39'));
      await tester.pumpAndSettle();
      expect(selected, 39);
      await tester.tap(find.byKey(const Key('long')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('anchored-menu-panel')), findsNothing);
    },
  );
  testWidgets(
    'list press changes text only without changing tap or scroll behavior',
    (tester) async {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      setDisplay(tester, const Size(800, 640));
      final api = EmbyClient(
        client: MockClient((_) async => http.Response('', 404)),
      )..session = syntheticSession();
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 140,
              child: MediaCard(
                item: MediaItem({
                  'Id': 'local',
                  'Name': '合成影片',
                  'Overview': '图文列表说明',
                }),
                api: api,
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      );
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('图文列表说明')),
      );
      await tester.pump();
      expect(find.byKey(const Key('poster-pressed')), findsNothing);
      expect(find.byKey(const Key('media-text-pressed')), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(taps, 1);
      expect(find.byKey(const Key('poster-pressed')), findsNothing);
      final drag = await tester.startGesture(
        tester.getCenter(find.text('合成影片')),
      );
      await tester.pump();
      await drag.moveBy(const Offset(0, 30));
      await tester.pump();
      expect(find.byKey(const Key('poster-pressed')), findsNothing);
      await drag.cancel();
      await tester.pumpWidget(const SizedBox());
      api.close();
    },
  );
  testWidgets('viewer caps at 500 while export keeps all 1600 records', (
    tester,
  ) async {
    final log = DiagnosticLog();
    for (var i = 0; i < 1600; i++) {
      log.add(LogArea.player, '合成日志 $i');
    }
    await tester.pumpWidget(MaterialApp(home: LogsPage(log: log)));
    await tester.pumpAndSettle();
    final list = tester.widget<SliverVariedExtentList>(
      find.byType(SliverVariedExtentList),
    );
    expect(list.delegate.estimatedChildCount, 999);
    final snapshot = LogExportSnapshot(log);
    expect(snapshot.lines.length, 1600);
    expect(snapshot.text, contains('合成日志 0'));
    expect(snapshot.lines.first, contains('合成日志 1599'));
    expect(log.entries.length, 1600);
    await tester.pumpWidget(const SizedBox());
    log.dispose();
  });
  test(
    'UTF-8 byte retention survives compaction and restart with newest full records',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final directory = await Directory.systemTemp.createTemp(
        'yingyu-072-log-',
      );
      try {
        final storage = LogFileStorage(File('${directory.path}/journal'));
        final log = await DiagnosticLog.open(prefs, storage: storage);
        for (var i = 0; i < 2600; i++) {
          log.add(LogArea.player, '记录 $i ${'诊断' * 590}');
        }
        await log.flush();
        expect(log.storedBytes, lessThanOrEqualTo(logStorageBytes));
        expect(log.entries.length, lessThan(2600));
        expect(log.entries.last.message, startsWith('记录 2599 '));
        expect(await storage.file.length(), lessThanOrEqualTo(logStorageBytes));
        final reopened = await DiagnosticLog.open(
          prefs,
          storage: LogFileStorage(storage.file),
        );
        expect(
          reopened.entries.map((e) => e.encode()),
          log.entries.map((e) => e.encode()),
        );
        expect(LogExportSnapshot(log).lines.length, log.entries.length);
        log.dispose();
        reopened.dispose();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  test(
    'avatar uses verified user metadata, account isolation, cache tags and safe failures',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final avatars = AccountAvatars(prefs);
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAE0lEQVR4nGNkaMpjgAEmOAsvBwAvdgD4kLdQ0AAAAABJRU5ErkJggg==',
      );
      var tag = 'one', images = 0, status = 200;
      final user = syntheticSession();
      final requests = <http.Request>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/Images/Primary')) {
            images++;
            expect(r.followRedirects, isFalse);
            expect(r.url.queryParameters['MaxWidth'], '256');
            expect(r.url.queryParameters.containsKey('api_key'), isFalse);
            return http.Response.bytes(
              png,
              status,
              headers: {'content-type': 'image/png'},
            );
          }
          return http.Response(
            jsonEncode({'Id': user.userId, 'PrimaryImageTag': tag}),
            200,
          );
        }),
      )..session = user;
      // Use the actual synthetic identity, never a real account.
      final verified = api;
      expect(await avatars.sync(verified), isFalse);
      expect(images, 0);
      await verified.validate();
      expect(await avatars.sync(verified), isTrue);
      expect(avatars.bytes(user), png);
      expect(images, 1);
      expect(await AccountAvatars(prefs).sync(verified), isTrue);
      expect(images, 1);
      expect(
        avatars.bytes(syntheticSession('http://other.invalid/emby')),
        isNull,
      );
      tag = 'two';
      status = 302;
      await verified.validate();
      expect(await avatars.sync(verified), isFalse);
      expect(images, 2);
      expect(avatars.bytes(user), png);
      expect(avatars.error(user), isNotNull);
      tag = '';
      await verified.validate();
      expect(await avatars.sync(verified), isTrue);
      expect(avatars.bytes(user), isNull);
      expect(images, 2);
      expect(
        prefs.getKeys().where((k) => k.startsWith('yingyu.avatar.')),
        isEmpty,
      );
      verified.retireBrowsing();
      avatars.dispose();
      api.close();
    },
  );
  test(
    'avatar late reply after account retirement cannot write its cache',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final avatars = AccountAvatars(prefs);
      final entered = Completer<void>(),
          response = Completer<http.StreamedResponse>();
      final api =
          EmbyClient(
              client: MockClient.streaming((request, body) {
                entered.complete();
                return response.future;
              }),
            )
            ..session = syntheticSession()
            ..primaryImageTag = 'old';
      final work = avatars.sync(api);
      await entered.future;
      api.retireBrowsing();
      response.complete(
        http.StreamedResponse(
          Stream.value([1, 2, 3]),
          200,
          headers: {'content-type': 'image/png'},
        ),
      );
      expect(await work, isFalse);
      expect(avatars.bytes(api.session!), isNull);
      expect(
        prefs.getKeys().where((key) => key.startsWith('yingyu.avatar.')),
        isEmpty,
      );
      avatars.dispose();
      api.close();
    },
  );
  for (final mode in ['oversized', 'invalid', 'unauthorized']) {
    test('avatar $mode does not replace cache or expire account', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final avatars = AccountAvatars(prefs);
      var expired = false;
      final api =
          EmbyClient(
              client: MockClient(
                (_) async => http.Response.bytes(
                  mode == 'oversized'
                      ? List.filled(AccountAvatars.maxBytes + 1, 1)
                      : [1, 2, 3],
                  mode == 'unauthorized' ? 401 : 200,
                  headers: {'content-type': 'image/png'},
                ),
              ),
            )
            ..session = syntheticSession()
            ..primaryImageTag = 'tag'
            ..onUnauthorized = () => expired = true;
      expect(await avatars.sync(api), isFalse);
      expect(expired, isFalse);
      expect(avatars.bytes(api.session!), isNull);
      expect(avatars.error(api.session!), isNotNull);
      avatars.dispose();
      api.close();
    });
  }
}
