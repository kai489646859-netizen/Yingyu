import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'host/hdr105_old_page.dart' as old;
import 'playback_test.dart' show FakeBackend;
import 'core_test.dart' show response, playbackData, syntheticSession;

class ColoredVideo extends FakeBackend {
  @override
  Widget view(BoxFit fit) => const ColoredBox(
    key: Key('synthetic-live-video'),
    color: Color(0xffff00ff),
  );
}

void main() {
  for (final failBeforeReady in [false, true]) {
    testWidgets(
      'preliminary video stays mounted and covered before readiness; failure=$failBeforeReady',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
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
        addTearDown(
          () => messenger.setMockMethodCallHandler(Device.channel, null),
        );
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        final api = EmbyClient(
          client: MockClient(
            (request) async => request.url.path.endsWith('PlaybackInfo')
                ? response(jsonEncode(playbackData()), 200)
                : request.url.path.contains('Sessions/Playing')
                ? response('', 204)
                : response('{"Id":"movie","Type":"Movie"}', 200),
          ),
        )..session = syntheticSession();
        final backend = ColoredVideo();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        final boundary = GlobalKey();
        final Widget page = const bool.fromEnvironment('OLD_COVER')
            ? old.PlayerPage(createSession: () => session)
            : PlayerPage(createSession: () => session);
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(key: boundary, child: page),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(session.loading, true);
        final videoElement = tester.element(
          find.byKey(const Key('synthetic-live-video')),
        );
        Future<int> pixel() async => (await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final offset = (300 * image.width + 40) * 4;
          final rgb =
              (bytes!.getUint8(offset) << 16) |
              (bytes.getUint8(offset + 1) << 8) |
              bytes.getUint8(offset + 2);
          image.dispose();
          return rgb;
        }))!;
        try {
          expect(
            await pixel(),
            0,
            reason: 'Initial decoder/Surface frames must be covered completely',
          );
          if (failBeforeReady) {
            backend.failures.add('合成开播失败');
            await tester.pump(const Duration(milliseconds: 100));
            expect(session.error, isNotNull);
            expect(session.loading, false);
            expect(session.ready, false);
            expect(
              await pixel(),
              0,
              reason:
                  'An opening error must not reveal the rejected preliminary frame',
            );
            return;
          }
          backend.gate.complete();
          for (var i = 0; i < 15; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(session.ready, true);
          expect(
            tester.element(find.byKey(const Key('synthetic-live-video'))),
            same(videoElement),
          );
          expect(
            await pixel(),
            0xff00ff,
            reason: 'The same video is revealed after readiness',
          );
        } finally {
          if (!backend.gate.isCompleted) backend.gate.complete();
          await tester.pumpWidget(const SizedBox.shrink());
          for (var i = 0; i < 20 && !backend.disposed; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(backend.disposed, true);
          api.close();
          await store.log.flush();
          store.log.dispose();
          store.dispose();
        }
      },
    );
  }
}
