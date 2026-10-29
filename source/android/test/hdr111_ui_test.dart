import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/diagnostics.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'track_menu_test.dart' show MenuBackend;

class StageBackend extends MenuBackend implements OpeningTracksBackend {
  final settle = Completer<void>();
  @override
  bool get prepareTracksWhilePaused => true;
  @override
  Future<void> settleOpeningTracks() => settle.future;
  void stage(String text) {
    snapshot = PlaybackSnapshot(
      duration: snapshot.duration,
      openingStage: text,
    );
    updates.add(snapshot);
  }
}

void main() {
  testWidgets(
    'real player loading overlay follows stages and leaves after readiness',
    (tester) async {
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
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final detail = Completer<void>();
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (request.url.path.contains('Sessions/Playing')) {
            return response('', 204);
          }
          await detail.future;
          return response('{"Id":"movie","Type":"Movie"}', 200);
        }),
      )..session = syntheticSession();
      final backend = StageBackend()..gate.complete();
      late PlaybackSession session;
      final key = GlobalKey();
      tester.view.physicalSize = const Size(900, 500);
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
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: PlayerPage(
              createSession: () => session = PlaybackSession(
                api: api,
                store: store,
                item: MediaItem({'Id': 'movie'}),
                backend: backend,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('正在读取影片信息'), findsOneWidget);
      detail.complete();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.loading, true);
      for (final stage in ['snapshot', 'hdr-frame', 'restore-frame']) {
        final label = hdrLoadingMessage(stage)!;
        backend.stage(label);
        await tester.pump();
        await tester.pump();
        expect(find.text(label), findsOneWidget);
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final file = File('build/ui-previews/$appVersion-hdr-$stage.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
        });
      }
      backend.settle.complete();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.ready, true);
      expect(session.loading, false);
      expect(find.byKey(const Key('playback-opening-feedback')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(backend.dispose);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      messenger.setMockMethodCallHandler(Device.channel, null);
    },
  );
}
