import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/adjustment_panels.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/media_notice.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, playbackData, response;
import 'subtitle_memory102_test.dart' show ScopedRememberedBackend;

class StartBackend extends ScopedRememberedBackend
    implements MediaNoticeBackend {
  final startGate = Completer<void>();
  bool waitingToPlay = false;
  Completer<void>? disposalGate;
  @override
  Future<void> dispose() async {
    if (disposalGate?.isCompleted == false) await disposalGate!.future;
    await super.dispose();
  }

  @override
  String get sourceNotice => mediaNotice(
    bluray: true,
    streams: const [],
    decoded: const {
      'video-format': 'h264',
      'video-params/gamma': 'bt.1886',
      'video-params/primaries': 'bt.709',
    },
  );
  @override
  Future<void> play() async {
    waitingToPlay = true;
    await startGate.future;
    await super.play();
  }
}

void main() {
  late AppStore store;
  late EmbyClient api;
  late StartBackend backend;
  late PlaybackSession session;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('PlaybackInfo')) {
          return response(jsonEncode(playbackData()), 200);
        }
        if (request.url.path.contains('Sessions/Playing')) {
          return response('', 204);
        }
        return response('{"Id":"movie","Type":"Movie"}', 200);
      }),
    )..session = syntheticSession();
  });
  void create() {
    backend = StartBackend()..gate.complete();
    session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
  }

  Future<void> cleanup(WidgetTester tester) async {
    if (!backend.startGate.isCompleted) backend.startGate.complete();
    backend.pending?.complete();
    if (backend.disposalGate?.isCompleted == false) {
      backend.disposalGate!.complete();
    }
    await tester.pump();
    unawaited(session.close());
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await backend.dispose();
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    });
  }

  testWidgets('reported SDR disc produces one established output notice', (
    tester,
  ) async {
    create();
    addTearDown(() => cleanup(tester));
    backend.startGate.complete();
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      Device.channel,
      (call) async => call.method == 'focus'
          ? true
          : call.method == 'levels'
          ? {'brightness': .5, 'volume': .5}
          : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(Device.channel, null));
    await tester.pumpWidget(
      MaterialApp(home: PlayerPage(createSession: () => session)),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('source-notice')), findsOneWidget);
    expect(backend.sourceNotice, contains('SDR'));
    expect(backend.sourceNotice, contains('蓝光原盘'));
    await tester.pump(const Duration(seconds: 8));
    expect(find.byKey(const Key('source-notice')), findsNothing);
  });
  testWidgets(
    'pending first play stays opening rather than exposing paused controls',
    (tester) async {
      create();
      addTearDown(() => cleanup(tester));
      final commands = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(Device.channel, (call) async {
        commands.add(call.method);
        return call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(Device.channel, null),
      );
      await tester.pumpWidget(
        MaterialApp(home: PlayerPage(createSession: () => session)),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        backend.waitingToPlay,
        true,
        reason:
            "ready=${session.ready}, loading=${session.loading}, error=${session.error}, closed=${session.closed}, background=${session.background}",
      );
      final controls = tester.widget<PlayerChrome>(find.byType(PlayerChrome));
      expect(
        controls.ready,
        false,
        reason: 'A queued play is still loading, not a user pause.',
      );
      expect(
        find.byKey(const Key('playback-opening-feedback')),
        findsOneWidget,
      );
      await tester.dragFrom(const Offset(100, 240), const Offset(0, -80));
      await tester.dragFrom(const Offset(700, 240), const Offset(0, -80));
      await tester.pump();
      expect(commands.where((c) => c == 'brightness'), isNotEmpty);
      expect(commands.where((c) => c == 'volume'), isNotEmpty);
      expect(backend.plays, 0);
      backend.startGate.complete();
      await tester.pump();
      await tester.pump();
      final started = tester.widget<PlayerChrome>(find.byType(PlayerChrome));
      expect(started.ready, true);
      expect(started.playing, true);
      expect(find.byKey(const Key('playback-opening-feedback')), findsNothing);
    },
  );
  testWidgets(
    'live subtitle drag never flashes a busy spinner or changes panel extent',
    (tester) async {
      create();
      addTearDown(() => cleanup(tester));
      session.ready = true;
      session.loading = false;
      backend.pending = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: SubtitlePositionMenu(session: session, onBack: () {}),
        ),
      );
      await tester.pumpAndSettle();
      final slider = find.byKey(const Key('subtitle-position-slider'));
      final before = tester.getRect(slider);
      tester.widget<CupertinoSlider>(slider).onChanged!(35);
      await tester.pump();
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(tester.getRect(slider), before);
      tester.widget<CupertinoSlider>(slider).onChanged!(45);
      await tester.pump();
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      backend.pending!.complete();
      backend.pending = null;
      await tester.pump();
      await tester.pump();
      expect(tester.widget<CupertinoSlider>(slider).value, 45);
    },
  );
  testWidgets(
    'repeated tablet system back cannot pop a player before cleanup finishes',
    (tester) async {
      create();
      addTearDown(() => cleanup(tester));
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      backend.startGate.complete();
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
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlayerPage(createSession: () => session),
                  ),
                ),
                child: const Text('synthetic home'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('synthetic home'));
      await tester.pumpAndSettle();
      expect(session.ready, true);
      backend.disposalGate = Completer<void>();
      await tester.binding.handlePopRoute();
      await tester.pump();
      final scope = tester.widget<PopScope>(
        find.byWidgetPredicate((w) => w is PopScope).last,
      );
      expect(
        scope.canPop,
        false,
        reason: 'A second system back must not bypass cleanup.',
      );
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byType(PlayerPage),
        findsOneWidget,
        reason: 'The playback route must own cleanup until its one final pop.',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
