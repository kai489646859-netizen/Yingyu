import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

// Only streams and texture identifiers are simulated. Video is the real pinned
// media_kit_video widget; no VideoController constructor or native engine runs.
class StreamPlayer extends PlatformPlayer {
  StreamPlayer()
    : super(configuration: const PlayerConfiguration(libass: true));
  void dimensions(int width, int height) {
    state = state.copyWith(width: width, height: height);
    widthController.add(width);
    heightController.add(height);
  }
}

class TextureOutput extends PlatformVideoController {
  TextureOutput(Player player)
    : super(player, const VideoControllerConfiguration()) {
    id.value = 42;
    rect.value = const Rect.fromLTWH(0, 0, 1920, 1080);
  }
  @override
  Future<void> setSize({int? width, int? height}) async {}
}

class StreamVideoController implements VideoController {
  StreamVideoController(this.player)
    : notifier = ValueNotifier(TextureOutput(player));
  @override
  final Player player;
  @override
  final ValueNotifier<PlatformVideoController?> notifier;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TextureBackend extends FakeBackend {
  TextureBackend(this.fail);
  final bool fail;
  final native = StreamPlayer();
  late final controller = StreamVideoController(Player(platformPlayer: native));
  @override
  Widget view(BoxFit fit) => Video(
    controller: controller,
    controls: NoVideoControls,
    fit: fit,
    wakelock: false,
  );
  @override
  Future<void> open(PlaybackRoute route, Duration start) async {
    await super.open(route, start);
    if (fail) throw const AppFailure('合成 HTTP 502');
    native.dimensions(1920, 1080);
  }
}

void main() {
  testWidgets('fresh Video reveals texture when its first dimensions arrive', (
    tester,
  ) async {
    final backend = TextureBackend(false);
    await tester.pumpWidget(MaterialApp(home: backend.view(BoxFit.contain)));
    expect(find.byType(Texture), findsNothing);
    backend.native.dimensions(3840, 2160);
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await backend.dispose();
      await backend.native.dispose();
    });
    backend.controller.notifier.value?.dispose();
    backend.controller.notifier.dispose();
    expect(tester.takeException(), null);
  });
  testWidgets(
    'failed open then retry attaches real Video to the new dimension streams',
    (tester) async {
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
      final backends = <TextureBackend>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PlayerPage(
            createSession: () {
              final backend = TextureBackend(backends.isEmpty)..gate.complete();
              backends.add(backend);
              return PlaybackSession(
                api: api,
                store: store,
                item: MediaItem({'Id': 'movie'}),
                backend: backend,
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('合成 HTTP 502'), findsOneWidget);
      expect(find.byType(Texture), findsNothing);
      await tester.tap(find.text('重试'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pumpAndSettle();
        if (backends.length == 2 && backends.last.plays > 0) break;
      }
      expect(backends.length, 2);
      expect(
        backends.last.plays,
        1,
        reason: 'audio/playback can be running during the display regression',
      );
      expect(
        find.byType(Texture),
        findsOneWidget,
        reason: 'new dimensions must reveal the video texture after retry',
      );
      final videoState = tester.state(find.byType(Video));
      backends.last.native.dimensions(1080, 1920);
      await tester.pump();
      expect(
        tester.state(find.byType(Video)),
        same(videoState),
        reason: 'ordinary frame/rotation updates must not remount the video',
      );
      expect(find.byType(Texture), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        for (final backend in backends) {
          await backend.dispose();
          await backend.native.dispose();
          backend.controller.notifier.value?.dispose();
          backend.controller.notifier.dispose();
        }
      });
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      expect(tester.takeException(), null);
    },
  );
}
