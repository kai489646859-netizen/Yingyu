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
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;

class NoticeBackend extends FakeBackend implements MediaNoticeBackend {
  @override
  String get sourceNotice => 'SDR · 已做色彩适配';
}

void main() {
  testWidgets(
    'foreground refreshes detail and library from the server without playing media',
    (tester) async {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      var minutes = 1;
      final paths = <String>[];
      Map<String, dynamic> movie() => {
        'Id': 'movie',
        'Name': '合成影片',
        'Type': 'Movie',
        'UserData': {'PlaybackPositionTicks': minutes * 600000000},
      };
      final api = EmbyClient(
        client: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('/Views')) {
            return response('{"Items":[]}', 200);
          }
          if (request.url.path.endsWith('/Items')) {
            return response(
              jsonEncode({
                'Items': [movie()],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          return response(jsonEncode(movie()), 200);
        }),
      )..session = syntheticSession();
      await tester.pumpWidget(
        MaterialApp(
          home: DetailPage(
            item: MediaItem(movie()),
            api: api,
            play: (_, _, _) async => fail('Foreground must not play media'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.text('看到 01:00'), findsOneWidget);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      minutes = 12;
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.text('继续观看'), findsOneWidget);
      expect(find.text('看到 12:00'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(
              api: api,
              onItem: (_) async => fail('Refresh must not play media'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已看 12 分钟'), findsOneWidget);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      minutes = 3; // A newer PC seek backwards is authoritative too.
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(find.text('已看 3 分钟'), findsOneWidget);
      expect(
        paths.any((p) => p.contains('PlaybackInfo') || p.contains('Playing')),
        false,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      api.close();
    },
  );
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    testWidgets(
      'resource notice lasts one brief visible budget per open at $size without intercepting playback',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          Device.channel,
          (call) async => call.method == 'focus'
              ? true
              : call.method == 'levels'
              ? {'brightness': .5, 'volume': .5}
              : null,
        );
        for (final font in {
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          'packages/cupertino_icons/CupertinoIcons':
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
        final font = Platform.environment['YINGYU_TEST_FONT'];
        if (font != null) {
          await (FontLoader('Roboto')..addFont(
                Future.value(
                  ByteData.sublistView(File(font).readAsBytesSync()),
                ),
              ))
              .load();
        }
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        var opens = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('PlaybackInfo')) {
              opens++;
              return response(jsonEncode(playbackData()), 200);
            }
            if (request.url.path.contains('Sessions/Playing')) {
              return response('', 204);
            }
            return response(
              '{"Id":"movie","Name":"合成片源信息预览","Type":"Movie"}',
              200,
            );
          }),
        )..session = syntheticSession();
        final backend = NoticeBackend()..gate.complete();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie', 'Name': '合成片源信息预览'}),
          backend: backend,
        );
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData.dark(),
              home: PlayerPage(createSession: () => session),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('source-notice')), findsOneWidget);
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(
            'build/ui-previews/$appVersion-resource-notice-${size.width.toInt()}.png',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.tap(find.byTooltip('暂停'));
        await tester.pump();
        expect(backend.snapshot.playing, false);
        await tester.pump(const Duration(seconds: 1));
        expect(find.byKey(const Key('source-notice')), findsOneWidget);
        await tester.pump(const Duration(seconds: 7));
        expect(find.byKey(const Key('source-notice')), findsNothing);
        await session.seek(const Duration(seconds: 42));
        await tester.pump();
        expect(find.byKey(const Key('source-notice')), findsNothing);
        expect(opens, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        for (var i = 0; i < 20 && !backend.disposed; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
        }
        expect(backend.disposed, true);
        messenger.setMockMethodCallHandler(Device.channel, null);
        api.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
      },
    );
  }
}
