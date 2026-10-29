import 'dart:convert';
import 'dart:io';
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
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/info.dart';
import 'package:yingyu/version.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'track_menu_test.dart' show MenuBackend;
import 'host/notice103/old_page.dart' as old;
import 'host/notice103/notice_projection.dart';
import 'player_episode_menu_test.dart' show fonts;
import 'package:media_kit/media_kit.dart' show VideoParams;

class _NoticeBackend extends MenuBackend implements MediaNoticeBackend {
  bool initiallyBuffering = false;
  String label = 'SDR · 已做色彩适配';
  NoticeProjection? projection;
  @override
  String get sourceNotice => projection?.sourceNotice ?? label;

  @override
  Future<void> open(PlaybackRoute route, Duration start) async {
    await super.open(route, start);
    snapshot = PlaybackSnapshot(position: start, duration: snapshot.duration);
  }

  void buffer(bool value) {
    snapshot = PlaybackSnapshot(
      position: snapshot.position,
      duration: snapshot.duration,
      playing: snapshot.playing,
      buffering: value,
    );
    updates.add(snapshot);
  }

  @override
  Future<void> play() async {
    await super.play();
    if (initiallyBuffering) buffer(true);
  }
}

void main() {
  setUpAll(fonts);
  final previewKey = GlobalKey();
  late AppStore store;
  late EmbyClient api;
  late PlaybackSession session;
  late _NoticeBackend backend;
  final backends = <_NoticeBackend>[];
  var opens = 0;
  var initialLabel = 'SDR · 已做色彩适配';
  var useProjection = false;
  var initialSeconds = 0;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    opens = 0;
    initialLabel = 'SDR · 已做色彩适配';
    useProjection = false;
    initialSeconds = 0;
    backends.clear();
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.endsWith('PlaybackInfo')) {
          opens++;
          return response(jsonEncode(playbackData()), 200);
        }
        if (request.url.path.contains('Sessions/Playing')) {
          return response('', 204);
        }
        return response(
          jsonEncode({
            'Id': 'movie',
            'Type': 'Movie',
            'RunTimeTicks': 54000000000,
            'UserData': {'PlaybackPositionTicks': initialSeconds * 10000000},
          }),
          200,
        );
      }),
    )..session = syntheticSession();
  });

  Future<void> launch(
    WidgetTester tester, {
    bool buffered = false,
    bool released = false,
  }) async {
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
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        for (final player in backends) {
          await player.dispose();
        }
      });
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      messenger.setMockMethodCallHandler(Device.channel, null);
    });
    PlaybackSession make() {
      backend = _NoticeBackend()
        ..label = initialLabel
        ..projection = useProjection
            ? (NoticeProjection()..snapshot(ready: false))
            : null
        ..initiallyBuffering = buffered && backends.isEmpty
        ..gate.complete();
      backends.add(backend);
      return session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: MaterialApp(
          home: released
              ? old.PlayerPage(createSession: make)
              : PlayerPage(createSession: make),
        ),
      ),
    );
    // A buffering spinner never settles; use bounded frames for that case.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(session.ready, true);
  }

  final notice = find.byKey(const Key('source-notice'));
  for (final seconds in [234, 5300]) {
    testWidgets('opening notice appears at resumed position $seconds', (
      tester,
    ) async {
      initialSeconds = seconds;
      await launch(tester);
      expect(backend.initial, Duration(seconds: seconds));
      expect(notice, findsOneWidget);
      expect(opens, 1);
      await tester.pump(const Duration(seconds: 8));
      expect(notice, findsNothing);
    });
  }
  testWidgets(
    'buffering remains clear after controls hide and disappears on recovery',
    (tester) async {
      await launch(tester);
      backend.buffer(true);
      await tester.pump();
      await tester.pump();
      expect(find.text('正在缓冲'), findsOneWidget);
      await tester.tapAt(const Offset(640, 250));
      await tester.pump(const Duration(seconds: 4));
      final dynamic page = tester.state(find.byType(PlayerPage));
      expect(page.controls, false);
      expect(find.byKey(const Key('playback-buffer-feedback')), findsOneWidget);
      backend.buffer(false);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('playback-buffer-feedback')), findsNothing);
      expect(opens, 1);
    },
  );
  testWidgets(
    'movie end is explicit and replay uses the same media without reopening',
    (tester) async {
      await launch(tester);
      final duration = backend.snapshot.duration;
      await session.seek(duration - const Duration(seconds: 1));
      backend.snapshot = PlaybackSnapshot(
        position: duration,
        duration: duration,
        completed: true,
      );
      backend.updates.add(backend.snapshot);
      await tester.pump();
      await tester.pump();
      expect(session.completed, true);
      expect(find.text('影片已播放完'), findsOneWidget);
      await tester.tap(find.byKey(const Key('playback-end-replay')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.completed, false);
      expect(find.byKey(const Key('playback-ended-feedback')), findsNothing);
      expect(opens, 1);
    },
  );
  testWidgets(
    'transient completion in the middle cannot display an end notice',
    (tester) async {
      await launch(tester);
      backend.snapshot = PlaybackSnapshot(
        position: const Duration(seconds: 10),
        duration: backend.snapshot.duration,
        completed: true,
      );
      backend.updates.add(backend.snapshot);
      await tester.pump();
      await tester.pump();
      expect(session.completed, false);
      expect(find.byKey(const Key('playback-ended-feedback')), findsNothing);
    },
  );
  for (final released in [true, false]) {
    testWidgets(
      'full ${released ? 'released102' : 'current103'} page with format arriving after readiness',
      (tester) async {
        initialLabel = '';
        await launch(tester, released: released);
        expect(notice, released ? findsNothing : findsOneWidget);
        backend.label = 'HDR10 · 高动态范围';
        backend.buffer(false);
        await tester.pump();
        await tester.pump();
        expect(
          notice,
          released ? findsNothing : findsOneWidget,
          reason:
              'A missing first snapshot must not permanently disable the opening notice',
        );
        await tester.pump(const Duration(seconds: 8));
        expect(notice, findsNothing);
        backend.buffer(false);
        await tester.pump();
        expect(
          notice,
          findsNothing,
          reason: 'A completed presentation cannot restart',
        );
        expect(opens, 1);
      },
    );
  }
  testWidgets(
    'late decoded color drives the actual backend notice getter and full page without another media request',
    (tester) async {
      useProjection = true;
      await launch(tester);
      expect(find.text('画面格式信息暂未提供'), findsOneWidget);
      backend.projection!.snapshot();
      backend.projection!.player.state.videoParams = const VideoParams(
        gamma: 'pq',
        colormatrix: 'bt.2020-ncl',
      );
      backend.buffer(false);
      await tester.pump();
      await tester.pump();
      expect(notice, findsOneWidget);
      expect(find.text('SDR · 已做色彩适配'), findsOneWidget);
      expect(opens, 1);
    },
  );
  testWidgets(
    'opening a menu while format is pending preserves the startup notice',
    (tester) async {
      initialLabel = '';
      await launch(tester);
      await tester.tap(find.byTooltip('播放器菜单'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(PlayerPage))).pop();
      await tester.pumpAndSettle();
      backend.label = 'HDR10 · 高动态范围';
      backend.buffer(false);
      await tester.pump();
      await tester.pump();
      expect(notice, findsOneWidget);
      expect(find.text('HDR10 · 高动态范围'), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      expect(notice, findsNothing);
      expect(opens, 1);
    },
  );
  testWidgets(
    'a temporary empty format does not remove a presented notice or renew its budget',
    (tester) async {
      initialLabel = 'HDR10 · 高动态范围';
      await launch(tester);
      final element = tester.element(find.byType(SourceFormatNotice));
      await tester.pump(const Duration(milliseconds: 900));
      backend.label = '';
      backend.buffer(false);
      await tester.pump();
      await tester.pump();
      expect(notice, findsOneWidget);
      expect(tester.element(find.byType(SourceFormatNotice)), same(element));
      backend.label = 'SDR · 已做色彩适配';
      backend.buffer(false);
      await tester.pump();
      await tester.pump();
      expect(tester.element(find.byType(SourceFormatNotice)), same(element));
      await tester.pump(const Duration(seconds: 8));
      expect(notice, findsNothing);
      expect(opens, 1);
    },
  );
  testWidgets(
    'a delayed format still appears in its current open after fifteen seconds',
    (tester) async {
      initialLabel = '';
      await launch(tester);
      await tester.pump(const Duration(seconds: 16));
      backend.label = 'HDR10 · 高动态范围';
      backend.buffer(false);
      await tester.pump();
      await tester.pump();
      expect(notice, findsOneWidget);
      expect(find.text('HDR10 · 高动态范围'), findsOneWidget);
      expect(opens, 1);
    },
  );
  testWidgets('each automatic open presents its format even when unchanged', (
    tester,
  ) async {
    await launch(tester);
    await tester.pump(const Duration(seconds: 8));
    expect(notice, findsNothing);
    final dynamic page = tester.state(find.byType(PlayerPage));
    session.removeListener(page.changed);
    var closed = false, started = false;
    final closing = session.close().then((_) => closed = true);
    final opening = page.start(automatic: true) as Future<void>;
    opening.then((_) => started = true);
    for (var n = 0; n < 80 && (!closed || !started); n++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(closed && started, true);
    await opening;
    await closing;
    expect(notice, findsOneWidget);
    expect(find.text(initialLabel), findsOneWidget);
    expect(opens, 2);
  });
  for (final menu in ['字幕', '音频', '播放速度', '播放器菜单', '影片与播放信息']) {
    testWidgets(
      'early $menu keeps the opening source notice rendered beneath the menu',
      (tester) async {
        await launch(tester);
        expect(notice, findsOneWidget);
        await tester.tap(find.byTooltip(menu));
        await tester.pumpAndSettle();
        expect(notice, findsOneWidget);
        expect(
          tester
              .widget<SourceFormatNotice>(find.byType(SourceFormatNotice))
              .visible,
          true,
        );
        if (menu == '影片与播放信息') {
          expect(
            ModalRoute.of(
              tester.element(find.byType(PlaybackInfoPage)),
            )!.isCurrent,
            true,
          );
          expect(
            ModalRoute.of(
              tester.element(find.byType(SourceFormatNotice)),
            )!.isCurrent,
            false,
            reason:
                'The information popup remains above the player notice; the notice must not become a root overlay.',
          );
        }
        if (menu == '音频' || menu == '影片与播放信息') {
          await tester.runAsync(() async {
            final boundary =
                previewKey.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'build/ui-previews/$appVersion-notice-${menu == '音频' ? 'audio' : 'info'}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        switch (menu) {
          case '字幕':
            await tester.tap(find.text('关闭字幕'));
          case '音频':
            await tester.tap(find.text('日语 · DTS · 5.1 声道'));
          case '播放速度':
            await tester.tap(find.text('2.0×'));
          default:
            Navigator.of(tester.element(find.byType(PlayerPage))).pop();
        }
        await tester.pumpAndSettle();
        expect(
          notice,
          findsOneWidget,
          reason: 'early menu cannot consume the opening notice',
        );
        if (menu == '字幕') expect(backend.selectedSubtitleId, 'no');
        if (menu == '音频') expect(backend.selectedAudioId, '2');
        if (menu == '播放速度') expect(backend.speed, 2);
        await tester.pump(const Duration(seconds: 8));
        expect(notice, findsNothing);
        await session.seek(const Duration(seconds: 25));
        await tester.pump();
        expect(notice, findsNothing);
        expect(opens, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an expanded audio menu consumes the original five visible seconds without restarting on close',
    (tester) async {
      await launch(tester);
      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.byTooltip('音频'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(notice, findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(notice, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(notice, findsNothing);
      Navigator.of(tester.element(find.byType(PlayerPage))).pop();
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
      expect(opens, 1);
    },
  );
  testWidgets(
    'early buffering never hides and replays an already presented notice',
    (tester) async {
      await launch(tester, buffered: true);
      backend.buffer(false);
      await tester.pump();
      expect(notice, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      backend.buffer(true);
      await tester.pump();
      await tester.pump();
      expect(
        notice,
        findsOneWidget,
        reason:
            'The top notice stays continuous while the center spinner is visible',
      );
      await tester.pump(const Duration(milliseconds: 9576));
      expect(notice, findsNothing);
      backend.buffer(false);
      await tester.pump();
      await tester.pump();
      expect(
        notice,
        findsNothing,
        reason: 'The completed notice cannot restart after buffering',
      );
      await tester.pump(const Duration(milliseconds: 4600));
      expect(notice, findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(notice, findsNothing);
      backend.buffer(true);
      await tester.pump();
      backend.buffer(false);
      await tester.pump();
      expect(notice, findsNothing, reason: 'completed budget is never renewed');
      expect(opens, 1);
    },
  );

  testWidgets('menu opened during buffering preserves the remaining notice', (
    tester,
  ) async {
    await launch(tester);
    backend.buffer(true);
    await tester.pump();
    await tester.tap(find.byTooltip('播放器菜单'));
    await tester.pump(const Duration(milliseconds: 400));
    backend.buffer(false);
    await tester.pump();
    Navigator.of(tester.element(find.byType(PlayerPage))).pop();
    await tester.pumpAndSettle();
    expect(notice, findsOneWidget);
    await tester.pump(const Duration(seconds: 8));
    expect(notice, findsNothing);
    expect(opens, 1);
  });

  testWidgets('initial buffering waits for five seconds of presentation', (
    tester,
  ) async {
    await launch(tester, buffered: true);
    expect(notice, findsNothing);
    await tester.pump(const Duration(seconds: 8));
    backend.buffer(false);
    await tester.pump();
    expect(notice, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4900));
    expect(notice, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    expect(notice, findsNothing);
    backend.buffer(true);
    await tester.pump();
    backend.buffer(false);
    await tester.pumpAndSettle();
    expect(notice, findsNothing);
  });

  testWidgets('retry is a new open even with identical source format text', (
    tester,
  ) async {
    await launch(tester);
    final old = backend;
    final oldDone = tester
        .widget<SourceFormatNotice>(find.byType(SourceFormatNotice))
        .onDone;
    await tester.pump(const Duration(seconds: 2));
    backend.failures.add('合成播放错误');
    await tester.pumpAndSettle();
    expect(find.text('合成播放错误'), findsOneWidget);
    expect(notice, findsNothing);
    await tester.tap(find.text('重试'));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(old.disposed, true);
    expect(opens, 2);
    expect(notice, findsOneWidget);
    oldDone(); // A delayed completion must belong to its original open.
    await tester.pump();
    expect(notice, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(
      notice,
      findsOneWidget,
      reason: 'old timer cannot clear the new open',
    );
    await tester.pump(const Duration(seconds: 7));
    expect(notice, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expired notice stays dismissed after later track operations', (
    tester,
  ) async {
    await launch(tester);
    await tester.pump(const Duration(seconds: 8));
    expect(notice, findsNothing);
    for (final subtitles in [true, false]) {
      final options = subtitles ? backend.subtitleTracks : backend.audioTracks;
      await session.chooseTrack(subtitles, options.last);
      backend.buffer(true);
      await tester.pump();
      backend.buffer(false);
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
    }
    expect(opens, 1);
  });

  testWidgets('an output text change cannot restart this open presentation', (
    tester,
  ) async {
    await launch(tester);
    await tester.pump(const Duration(seconds: 2));
    backend.label = 'SDR · 已做色彩适配';
    backend.buffer(false);
    await tester.pump();
    expect(find.text(backend.label), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(notice, findsNothing);
    expect(opens, 1);
  });
}
