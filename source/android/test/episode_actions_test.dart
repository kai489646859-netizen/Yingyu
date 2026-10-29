import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/personal_library.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/episode_actions.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'track_menu_test.dart' show MenuBackend;
import 'personal_features_test.dart' show featureEpisode;

class DelayedSeekBackend extends MenuBackend implements MediaNoticeBackend {
  @override
  String sourceNotice = '';
  Completer<void>? seekGate;
  final seekTargets = <Duration>[];
  bool seekFails = false;
  bool emitEndBeforeSeekGate = false;
  bool clearEndBeforeSeekFuture = false;
  final earlyEndTransitions = <bool>[];
  @override
  Future<void> seek(Duration value) async {
    seekTargets.add(value);
    if (emitEndBeforeSeekGate && value == snapshot.duration) {
      // Model MPV's real EOF arriving before its seek command Future resolves.
      // Optionally model NativePlayer.seek clearing completed after its command
      // reply and before the seek Future resolves (real.dart:781-793).
      snapshot = PlaybackSnapshot(
        position: value,
        duration: snapshot.duration,
        completed: true,
      );
      updates.add(snapshot);
      earlyEndTransitions.add(true);
      await seekGate?.future;
      if (seekFails) throw StateError('synthetic seek failure');
      if (clearEndBeforeSeekFuture) {
        snapshot = PlaybackSnapshot(
          position: value,
          duration: snapshot.duration,
        );
        updates.add(snapshot);
        earlyEndTransitions.add(false);
      }
      return;
    }
    await seekGate?.future;
    if (seekFails) throw StateError('synthetic seek failure');
    await super.seek(value);
  }
}

void main() {
  late AppStore store;
  late EmbyClient api;
  late PlaybackSession session;
  final sessions = <PlaybackSession>[];
  final backends = <DelayedSeekBackend>[];
  final calls = <String>[];
  bool nextAvailable = true;
  Completer<void>? stopGate;
  final positions = <String, int>{};
  final notices = <String, String>{};

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    sessions.clear();
    backends.clear();
    calls.clear();
    positions.clear();
    notices.clear();
    stopGate = null;
    nextAvailable = true;
    api = EmbyClient(
      client: MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('PlaybackInfo')) {
          calls.add('open:${path.split('/')[path.split('/').length - 2]}');
          return response(jsonEncode(playbackData()), 200);
        }
        if (path.contains('Sessions/Playing')) {
          final body = object(jsonDecode(request.body));
          if (path.endsWith('Stopped')) {
            calls.add('stopping:${body['ItemId']}');
            await stopGate?.future;
            calls.add('saved:${body['ItemId']}');
          }
          positions['${body['ItemId']}'] = integer(body['PositionTicks']);
          return response('', 204);
        }
        if (path.endsWith('/Episodes')) {
          return response(
            jsonEncode({
              'Items': [
                featureEpisode('1').data,
                if (nextAvailable) featureEpisode('2').data,
              ],
            }),
            200,
          );
        }
        final id = path.split('/').last;
        return response(
          jsonEncode({
            ...featureEpisode(id).data,
            'UserData': {
              'PlaybackPositionTicks': positions[id] ?? 0,
              'Played': (positions[id] ?? 0) >= 5990000000,
            },
          }),
          200,
        );
      }),
    )..session = syntheticSession();
  });

  Future<void> launch(
    WidgetTester tester, {
    bool auto = true,
    bool sparse = false,
  }) async {
    await store.setAutoNext(auto);
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
    PlaybackSession make(MediaItem item) {
      final backend = DelayedSeekBackend()..gate.complete();
      backend.sourceNotice = notices[item.id] ?? '';
      backend.snapshot = const PlaybackSnapshot(
        duration: Duration(minutes: 10),
      );
      backends.add(backend);
      session = PlaybackSession(
        api: api,
        store: store,
        item: item,
        backend: backend,
      );
      sessions.add(session);
      return session;
    }

    addTearDown(() async {
      if (stopGate != null && !stopGate!.isCompleted) stopGate!.complete();
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      messenger.setMockMethodCallHandler(Device.channel, null);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: PlayerPage(
          createSession: () => make(
            sparse
                ? MediaItem({
                    'Id': '1',
                    'Type': 'Episode',
                    'SeriesId': 'series',
                  })
                : featureEpisode('1'),
          ),
          createSessionForItem: make,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(session.ready, true);
    expect(calls.where((c) => c.startsWith('open:')).length, 1);
  }

  Future<void> finish(WidgetTester tester, {bool genuine = true}) async {
    await session.seek(Duration(seconds: genuine ? 599 : 40));
    backends.last.snapshot = PlaybackSnapshot(
      position: Duration(seconds: genuine ? 600 : 40),
      duration: const Duration(minutes: 10),
      completed: true,
    );
    backends.last.updates.add(backends.last.snapshot);
    await tester.pump();
    await tester.pump();
  }

  Future<void> tick(
    WidgetTester tester,
    int seconds, {
    bool playing = true,
    bool buffering = false,
    bool completed = false,
  }) async {
    backends.last.snapshot = PlaybackSnapshot(
      position: Duration(seconds: seconds),
      duration: const Duration(minutes: 10),
      playing: playing,
      buffering: buffering,
      completed: completed,
    );
    backends.last.updates.add(backends.last.snapshot);
    await tester.pump();
    await tester.pump();
  }

  Future<void> saveRule({bool automatic = false, bool credits = false}) =>
      store.personal.setSkipRule(
        api.session!,
        featureEpisode('1'),
        SkipScope.season,
        SkipRule(
          intro: credits
              ? null
              : const IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
          creditsRemaining: credits ? const Duration(seconds: 120) : null,
          autoIntro: automatic && !credits,
          autoCredits: automatic && credits,
        ),
        const Duration(minutes: 10),
      );

  for (final hasNext in [false, true]) {
    testWidgets(
      'EOF is explicit when ${hasNext ? 'auto next is disabled' : 'there is no next episode'}',
      (tester) async {
        nextAvailable = hasNext;
        await launch(tester, auto: !hasNext);
        await finish(tester);
        expect(session.completed, true);
        expect(find.text('本集已播放完'), findsOneWidget);
        expect(find.text(hasNext ? '自动连播已关闭' : '暂无下一集'), findsOneWidget);
        expect(calls.where((c) => c.startsWith('open:')).length, 1);
        if (hasNext) {
          await tester.tap(find.byKey(const Key('playback-end-next')));
          for (var i = 0; i < 20; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(session.item.id, '2');
          expect(calls.indexOf('saved:1'), lessThan(calls.indexOf('open:2')));
        } else {
          expect(find.byKey(const Key('playback-end-next')), findsNothing);
        }
      },
    );
  }

  Future<void> elapseAuto(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump();
  }

  for (final start in [0, 120]) {
    testWidgets(
      'automatic intro merges into initial open only inside enabled range, resume=$start',
      (tester) async {
        await store.personal.setSkipRule(
          api.session!,
          featureEpisode('1'),
          SkipScope.season,
          const SkipRule(
            intro: IntroRange(Duration.zero, Duration(seconds: 90)),
            autoIntro: true,
          ),
          const Duration(minutes: 10),
        );
        positions['2'] = start * 10000000;
        await launch(tester);
        await session.seek(const Duration(seconds: 595));
        await tick(tester, 595);
        await tick(tester, 600, playing: false, completed: true);
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(session.item.id, '2');
        expect(
          backends.last.initial,
          Duration(seconds: start == 0 ? 90 : start),
        );
        expect(
          backends.last.seekTargets,
          isEmpty,
          reason: 'No second post-load intro seek',
        );
        expect(find.byKey(const Key('auto-skip-countdown')), findsNothing);
        if (start == 0) {
          expect(find.text('返回观看'), findsOneWidget);
          await tester.tap(find.text('返回观看'));
          await tester.pump();
          expect(backends.last.seekTargets, [Duration.zero]);
          await tester.pump(const Duration(seconds: 4));
          expect(find.byKey(const Key('auto-skip-countdown')), findsNothing);
        }
      },
    );
  }

  testWidgets(
    'manual next preserves ordinary intro handling even with an automatic rule',
    (tester) async {
      await store.personal.setSkipRule(
        api.session!,
        featureEpisode('1'),
        SkipScope.season,
        const SkipRule(
          intro: IntroRange(Duration.zero, Duration(seconds: 90)),
          autoIntro: true,
        ),
        const Duration(minutes: 10),
      );
      await launch(tester);
      await tester.tap(find.byTooltip('下一集'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.item.id, '2');
      expect(backends.last.initial, Duration.zero);
    },
  );

  for (final same in [true, false]) {
    testWidgets(
      'automatic next presents its own output notice even for the same format, same=$same',
      (tester) async {
        notices['1'] = 'HDR10 · 高动态范围';
        notices['2'] = same ? notices['1']! : 'SDR · 已做色彩适配';
        await launch(tester);
        expect(find.text(notices['1']!), findsOneWidget);
        await session.seek(const Duration(seconds: 595));
        await tick(tester, 595);
        await tick(tester, 600, playing: false, completed: true);
        for (var i = 0; i < 16; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(session.item.id, '2');
        expect(find.byKey(const Key('source-notice')), findsOneWidget);
        expect(find.text(notices['2']!), findsOneWidget);
        expect(calls.where((c) => c.startsWith('open:')).length, 2);
      },
    );
  }

  testWidgets(
    'tail notice uses media seconds, not extra wall-clock delay or media requests',
    (tester) async {
      await launch(tester);
      await session.seek(const Duration(seconds: 595));
      await tick(tester, 595, playing: false, buffering: true);
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
      await tick(tester, 596);
      expect(find.text('4 秒后播放下一集'), findsOneWidget);
      await tester.tap(find.text('取消连播'));
      await tick(tester, 600, playing: false, completed: true);
      await tester.pump(const Duration(seconds: 2));
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'natural EOF opens next without a second wait and saves previous episode first',
    (tester) async {
      await launch(tester);
      stopGate = Completer<void>();
      await session.seek(const Duration(seconds: 595));
      await tick(tester, 595);
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      expect(find.text('即将进入下一集'), findsNothing);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
      await tick(tester, 600, playing: false, completed: true);
      for (var i = 0; i < 1; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        calls,
        contains('stopping:1'),
        reason:
            'closed=${session.closed}; ready=${session.ready}; error=${session.error}; sync=${session.syncWarning}; labels=${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
      );
      expect(calls, isNot(contains('open:2')));
      stopGate!.complete();
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(calls.indexOf('saved:1'), lessThan(calls.indexOf('open:2')));
      expect(sessions.length, 2);
      expect(backends.first.disposed, true);
      expect(session.item.id, '2');
      expect(find.byKey(const Key('next-countdown')), findsNothing);
    },
  );

  testWidgets(
    'cancel at the EOF frame retires the already queued automatic advance',
    (tester) async {
      await launch(tester);
      await session.seek(const Duration(seconds: 595));
      await tick(tester, 595);
      final dynamic actions = tester.state(find.byType(EpisodeActions));
      WidgetsBinding.instance.addPostFrameCallback((_) => actions.cancel());
      await tick(tester, 600, playing: false, completed: true);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  for (final action in [
    'cancel',
    'background',
    'account',
    'disable',
    'seek',
    'menu',
    'unmount',
    'error',
  ]) {
    testWidgets('$action cancels countdown and never opens another resource', (
      tester,
    ) async {
      await launch(tester);
      await session.seek(const Duration(seconds: 595));
      await tick(tester, 595);
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      switch (action) {
        case 'cancel':
          await tester.tap(find.text('取消连播'));
        case 'background':
          await session.pauseForBackground();
        case 'account':
          api.session = syntheticSession();
          session.changed();
        case 'disable':
          await store.setAutoNext(false);
        case 'seek':
          await session.seek(const Duration(seconds: 20));
        case 'menu':
          await tester.tap(find.byTooltip('音频'));
        case 'unmount':
          await tester.pumpWidget(const SizedBox());
        case 'error':
          backends.last.failures.add('合成故障');
      }
      await tester.pump();
      if (!session.closed) {
        await tick(tester, 600, playing: false, completed: true);
      }
      await tester.pump(const Duration(seconds: 7));
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
    });
  }
  testWidgets(
    'manual next and previous each save the departing real episode before opening target',
    (tester) async {
      await launch(tester, auto: false);
      await session.seek(const Duration(seconds: 123));
      await tester.tap(find.byTooltip('下一集'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.item.id, '2');
      expect(positions['1'], 1230000000);
      expect(calls.indexOf('saved:1'), lessThan(calls.indexOf('open:2')));
      await session.seek(const Duration(seconds: 234));
      await tester.tap(find.byTooltip('上一集'));
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(session.item.id, '1');
      expect(positions['2'], 2340000000);
      expect(positions['1'], 1230000000);
      expect(calls.indexOf('saved:2'), lessThan(calls.lastIndexOf('open:1')));
    },
  );
  for (final spec in ['off', 'last', 'false-end']) {
    testWidgets('$spec does not begin auto next', (tester) async {
      nextAvailable = spec != 'last';
      await launch(tester, auto: spec != 'off');
      await finish(tester, genuine: spec != 'false-end');
      await tester.pump(const Duration(seconds: 7));
      expect(find.byKey(const Key('next-countdown')), findsNothing);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    });
  }
  for (final fails in [false, true]) {
    testWidgets('pending seek cancels auto next even when seek fails=$fails', (
      tester,
    ) async {
      await launch(tester);
      await session.seek(const Duration(seconds: 595));
      await tick(tester, 595);
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      final gate = Completer<void>();
      backends.single.seekGate = gate;
      final seek = session.seek(const Duration(seconds: 20));
      final completion = expectLater(
        seek,
        fails ? throwsStateError : completes,
      );
      try {
        await tester.pump();
        expect(find.byKey(const Key('next-countdown')), findsNothing);
        await tester.pump(const Duration(seconds: 7));
        expect(sessions.length, 1);
        expect(session.closed, false);
      } finally {
        if (fails) {
          gate.completeError(StateError('synthetic seek failure'));
        } else {
          gate.complete();
        }
        await completion;
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 7));
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
    });
  }
  testWidgets(
    'intro button only appears inside saved range and seeks without reopening',
    (tester) async {
      await store.personal.setIntro(
        api.session!,
        featureEpisode('1'),
        const IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
        const Duration(minutes: 10),
      );
      await launch(tester);
      expect(find.text('跳过片头'), findsNothing);
      await session.seek(const Duration(seconds: 20));
      await tester.pump();
      expect(find.text('跳过片头'), findsOneWidget);
      await tester.tap(find.text('跳过片头'));
      await tester.pump();
      expect(session.position.inSeconds, 90);
      expect(find.text('跳过片头'), findsNothing);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'latest opening metadata restores intro identity omitted from catalogue',
    (tester) async {
      await store.personal.setIntro(
        api.session!,
        featureEpisode('1'),
        const IntroRange(Duration(seconds: 10), Duration(seconds: 90)),
        const Duration(minutes: 10),
      );
      await launch(tester, sparse: true);
      expect(session.item.data['SeasonId'], null);
      expect(session.currentMetadata.data['SeasonId'], 's1');
      await session.seek(const Duration(seconds: 20));
      await tester.pump();
      expect(find.text('跳过片头'), findsOneWidget);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );
  testWidgets(
    'player menu saves an explicit intro range without seeking or reopening',
    (tester) async {
      await launch(tester);
      await tester.tap(find.byTooltip('播放器菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('片头片尾'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('skip-edit-intro')));
      await tester.pump();
      await tester.enterText(find.byType(CupertinoTextField).at(0), '0:05');
      await tester.enterText(find.byType(CupertinoTextField).at(1), '1:10');
      await tester.scrollUntilVisible(
        find.text('保存'),
        80,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      final range = store.personal.intro(api.session!, featureEpisode('2'))!;
      expect(range.start.inSeconds, 5);
      expect(range.end.inSeconds, 70);
      expect(session.position, Duration.zero);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets('saved manual rule stays manual during ordinary playback', (
    tester,
  ) async {
    await saveRule();
    await launch(tester);
    await tick(tester, 20);
    expect(find.text('跳过片头'), findsOneWidget);
    expect(session.position.inSeconds, 20);
    expect(backends.single.seekTargets, isEmpty);
    expect(calls.where((c) => c.startsWith('open:')).length, 1);
  });

  testWidgets(
    'automatic intro seeks once and dragging back keeps manual choice',
    (tester) async {
      await saveRule(automatic: true);
      await launch(tester);
      await tick(tester, 20);
      expect(find.text('3 秒后跳过片头'), findsOneWidget);
      expect(backends.single.seekTargets, isEmpty);
      await elapseAuto(tester);
      expect(session.position.inSeconds, 90);
      expect(backends.single.seekTargets, [const Duration(seconds: 90)]);
      await session.seek(const Duration(seconds: 20));
      await tester.pump();
      await tick(tester, 21);
      expect(session.position.inSeconds, 21);
      expect(backends.single.seekTargets.length, 2);
      expect(find.text('跳过片头'), findsOneWidget);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'saving automatic rule inside its current range does not seek on return',
    (tester) async {
      await launch(tester);
      await tick(tester, 20);
      await saveRule(automatic: true);
      await tester.pump();
      await tick(tester, 21);
      expect(session.position.inSeconds, 21);
      expect(backends.single.seekTargets, isEmpty);
      expect(find.text('跳过片头'), findsOneWidget);
    },
  );

  testWidgets(
    'saving unchanged automatic rule in editor does not seek on dismissal',
    (tester) async {
      await saveRule(automatic: true);
      await launch(tester);
      await tester.tap(find.byTooltip('播放器菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('片头片尾'));
      await tester.pumpAndSettle();
      await tick(tester, 20);
      expect(backends.single.seekTargets, isEmpty);
      await tester.scrollUntilVisible(
        find.text('保存'),
        80,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await tick(tester, 21);
      expect(backends.single.seekTargets, isEmpty);
      expect(session.position.inSeconds, 21);
      expect(find.text('跳过片头'), findsOneWidget);
    },
  );

  for (final blocker in [
    'pause',
    'buffering',
    'background',
    'menu',
    'account',
    'error',
  ]) {
    testWidgets('$blocker blocks automatic intro seek', (tester) async {
      await saveRule(automatic: true);
      await launch(tester);
      switch (blocker) {
        case 'pause':
          await backends.single.pause();
        case 'background':
          await session.pauseForBackground();
        case 'menu':
          await tester.tap(find.byTooltip('音频'));
          await tester.pumpAndSettle();
        case 'account':
          api.session = syntheticSession();
          session.changed();
        case 'error':
          backends.single.failures.add('synthetic playback error');
        case 'buffering':
          break;
      }
      await tick(
        tester,
        20,
        playing: blocker != 'pause',
        buffering: blocker == 'buffering',
      );
      expect(backends.single.seekTargets, isEmpty);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    });
  }

  testWidgets(
    'pending manual seek consumes automatic intro without a second seek',
    (tester) async {
      await saveRule(automatic: true);
      await launch(tester);
      final gate = Completer<void>();
      backends.single.seekGate = gate;
      final pending = session.seek(const Duration(seconds: 20));
      await tick(tester, 20);
      expect(backends.single.seekTargets, [const Duration(seconds: 20)]);
      gate.complete();
      await pending;
      await tester.pump();
      await tick(tester, 21);
      expect(backends.single.seekTargets, [const Duration(seconds: 20)]);
      expect(find.text('跳过片头'), findsOneWidget);
    },
  );

  testWidgets('unmount cancels a queued automatic skip', (tester) async {
    await saveRule(automatic: true);
    await launch(tester);
    backends.single.snapshot = const PlaybackSnapshot(
      position: Duration(seconds: 20),
      duration: Duration(minutes: 10),
      playing: true,
    );
    backends.single.updates.add(backends.single.snapshot);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(backends.single.seekTargets, isEmpty);
    expect(calls.where((c) => c.startsWith('open:')).length, 1);
  });

  testWidgets(
    'failed automatic skip is visible and never loops; manual retry remains',
    (tester) async {
      await saveRule(automatic: true);
      await launch(tester);
      backends.single.seekFails = true;
      await tick(tester, 20);
      await elapseAuto(tester);
      await tester.pump();
      expect(backends.single.seekTargets.length, 1);
      expect(find.textContaining('synthetic seek failure'), findsOneWidget);
      await tick(tester, 21);
      expect(backends.single.seekTargets.length, 1);
      backends.single.seekFails = false;
      await tester.tap(find.text('跳过片头'));
      await tester.pump();
      expect(backends.single.seekTargets.length, 2);
      expect(session.position.inSeconds, 90);
    },
  );

  for (final lastEpisode in [false, true]) {
    testWidgets(
      'manual credits reach real end without next=$lastEpisode or automatic next',
      (tester) async {
        nextAvailable = !lastEpisode;
        await saveRule(credits: true);
        await launch(tester, auto: lastEpisode);
        await tick(tester, 500);
        expect(find.text('跳过片尾'), findsOneWidget);
        await tester.tap(find.text('跳过片尾'));
        await tester.pump();
        expect(backends.single.seekTargets.last, const Duration(minutes: 10));
        expect(session.position, const Duration(minutes: 10));
        expect(
          session.completed,
          isFalse,
          reason: 'a seek is not a fabricated completion event',
        );
        expect(find.byKey(const Key('next-countdown')), findsNothing);
        await tick(tester, 600, playing: false, completed: true);
        expect(session.completed, isTrue);
        expect(find.byKey(const Key('next-countdown')), findsNothing);
        expect(calls.where((c) => c.startsWith('open:')).length, 1);
      },
    );
  }

  testWidgets(
    'automatic credits use seek then retain genuine five second cancellable next',
    (tester) async {
      await saveRule(automatic: true, credits: true);
      await launch(tester);
      await tick(tester, 500);
      expect(find.text('3 秒后跳过片尾'), findsOneWidget);
      await elapseAuto(tester);
      expect(backends.single.seekTargets, [const Duration(minutes: 10)]);
      expect(session.completed, isFalse);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
      await tick(tester, 600, playing: false, completed: true);
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      await tester.tap(find.text('取消连播'));
      await tester.pump(const Duration(seconds: 7));
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'automatic prompt offers immediate skip and return without replay loop',
    (tester) async {
      await saveRule(automatic: true);
      await launch(tester);
      await tick(tester, 20);
      expect(find.text('3 秒后跳过片头'), findsOneWidget);
      expect(backends.single.seekTargets, isEmpty);
      await tester.tap(find.text('立即跳过'));
      await tester.pump();
      expect(session.position.inSeconds, 90);
      expect(find.text('返回观看'), findsOneWidget);
      await tester.tap(find.text('返回观看'));
      await tester.pump();
      expect(session.position.inSeconds, 20);
      await tick(tester, 21);
      await elapseAuto(tester);
      expect(backends.single.seekTargets, [
        const Duration(seconds: 90),
        const Duration(seconds: 20),
      ]);
      expect(find.text('跳过片头'), findsOneWidget);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'cancel automatic prompt keeps this viewing manual without changing saved mode',
    (tester) async {
      await saveRule(automatic: true);
      await launch(tester);
      await tick(tester, 20);
      await tester.tap(find.text('本次不跳'));
      await tester.pump();
      await elapseAuto(tester);
      expect(session.position.inSeconds, 20);
      expect(backends.single.seekTargets, isEmpty);
      expect(find.text('跳过片头'), findsOneWidget);
      expect(
        store.personal
            .resolveSkipRule(session.account, session.currentMetadata)!
            .rule
            .autoIntro,
        isTrue,
      );
      await tick(tester, 21);
      await elapseAuto(tester);
      expect(backends.single.seekTargets, isEmpty);
    },
  );

  for (final buffering in [false, true]) {
    testWidgets(
      'pending countdown suspends while buffering=$buffering or paused',
      (tester) async {
        await saveRule(automatic: true);
        await launch(tester);
        await tick(tester, 20);
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('2 秒后跳过片头'), findsOneWidget);
        await tick(tester, 21, playing: buffering, buffering: buffering);
        await tester.pump(const Duration(seconds: 6));
        expect(backends.single.seekTargets, isEmpty);
        await tick(tester, 22);
        expect(find.text('2 秒后跳过片头'), findsOneWidget);
        await tester.pump(const Duration(seconds: 1));
        expect(backends.single.seekTargets, isEmpty);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(session.position.inSeconds, 90);
        expect(backends.single.seekTargets.length, 1);
      },
    );
  }

  for (final action in ['menu', 'background', 'seek', 'save']) {
    testWidgets('$action cancels an already pending automatic skip', (
      tester,
    ) async {
      await saveRule(automatic: true);
      await launch(tester);
      await tick(tester, 20);
      expect(find.byKey(const Key('auto-skip-countdown')), findsOneWidget);
      switch (action) {
        case 'menu':
          await tester.tap(find.byTooltip('音频'));
          await tester.pumpAndSettle();
          tester.state<NavigatorState>(find.byType(Navigator).first).pop();
          await tester.pumpAndSettle();
        case 'background':
          await session.pauseForBackground();
          await tester.pump();
          session.foreground();
          await backends.single.play();
        case 'seek':
          await session.seek(const Duration(seconds: 21));
        case 'save':
          await saveRule(automatic: true);
      }
      await tester.pump();
      await elapseAuto(tester);
      expect(find.byKey(const Key('auto-skip-countdown')), findsNothing);
      expect(
        backends.single.seekTargets,
        action == 'seek' ? [const Duration(seconds: 21)] : isEmpty,
      );
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    });
  }

  testWidgets(
    'return from real credits EOF cancels next and preserves the newer progress behind old stopped report',
    (tester) async {
      await saveRule(automatic: true, credits: true);
      await launch(tester);
      stopGate = Completer<void>();
      backends.single
        ..emitEndBeforeSeekGate = true
        ..clearEndBeforeSeekFuture = true;
      await tick(tester, 500);
      await elapseAuto(tester);
      expect(session.completed, isTrue);
      expect(backends.single.snapshot.completed, isFalse);
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      expect(find.text('返回观看'), findsOneWidget);
      await tester.tap(find.text('返回观看'));
      await tester.pump();
      expect(session.position.inSeconds, 500);
      expect(session.completed, isFalse);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
      stopGate!.complete();
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(positions['1'], 5000000000);
      expect(
        store.localProgress(session.account, '1'),
        const Duration(seconds: 500),
      );
      await tester.pump(const Duration(seconds: 7));
      expect(session.position.inSeconds, 500);
      expect(backends.single.seekTargets, [
        const Duration(minutes: 10),
        const Duration(seconds: 500),
      ]);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'return action expires and cannot linger across another manual seek',
    (tester) async {
      await saveRule();
      await launch(tester);
      await tick(tester, 20);
      await tester.tap(find.text('跳过片头'));
      await tester.pump();
      expect(find.text('返回观看'), findsOneWidget);
      await session.seek(const Duration(seconds: 30));
      await tester.pump();
      expect(find.text('返回观看'), findsNothing);
      await tester.tap(find.text('跳过片头'));
      await tester.pump();
      expect(find.text('返回观看'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('返回观看'), findsNothing);
    },
  );

  testWidgets(
    'credits EOF before seek Future confirms completion without another event',
    (tester) async {
      await saveRule(credits: true);
      await launch(tester);
      await tick(tester, 500);
      final gate = Completer<void>();
      backends.single
        ..seekGate = gate
        ..emitEndBeforeSeekGate = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tester.tap(find.text('跳过片尾'));
      await tester.pump();
      expect(session.seeking, isTrue);
      expect(backends.single.snapshot.completed, isTrue);
      expect(session.completed, isFalse);
      expect(store.completions.receipt(session.account, '1'), isNull);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(session.seeking, isFalse);
      expect(
        session.completed,
        isTrue,
        reason:
            'the real EOF must survive seek completion; no second event is emitted',
      );
      expect(store.completions.receipt(session.account, '1'), isNotNull);
      expect(
        store.completions.completed(session.account, session.currentMetadata),
        isTrue,
      );
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      await tester.tap(find.text('取消连播'));
      await tester.pump(const Duration(seconds: 7));
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'credits EOF then vendor clear before seek Future retains completion and countdown',
    (tester) async {
      await saveRule(credits: true);
      await launch(tester);
      await tick(tester, 500);
      final gate = Completer<void>();
      backends.single
        ..seekGate = gate
        ..emitEndBeforeSeekGate = true
        ..clearEndBeforeSeekFuture = true;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tester.tap(find.text('跳过片尾'));
      await tester.pump();
      expect(session.seeking, isTrue);
      expect(backends.single.earlyEndTransitions, [true]);
      expect(session.completed, isFalse);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(backends.single.earlyEndTransitions, [true, false]);
      expect(
        backends.single.snapshot.completed,
        isFalse,
        reason: 'vendor command cleanup follows a real EOF',
      );
      expect(session.seeking, isFalse);
      expect(
        session.completed,
        isTrue,
        reason: 'the same seek had a real EOF before the vendor clear',
      );
      expect(store.completions.receipt(session.account, '1'), isNotNull);
      expect(
        store.completions.completed(session.account, session.currentMetadata),
        isTrue,
      );
      expect(find.text('5 秒后播放下一集'), findsOneWidget);
      await tester.tap(find.text('取消连播'));
      await tester.pump(const Duration(seconds: 7));
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'credits seek Future without real EOF never fabricates completion',
    (tester) async {
      await saveRule(credits: true);
      await launch(tester);
      await tick(tester, 500);
      final gate = Completer<void>();
      backends.single.seekGate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await tester.tap(find.text('跳过片尾'));
      await tester.pump();
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(session.position, const Duration(minutes: 10));
      expect(backends.single.snapshot.completed, isFalse);
      expect(session.completed, isFalse);
      expect(store.completions.receipt(session.account, '1'), isNull);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
      expect(calls.where((c) => c.startsWith('open:')).length, 1);
    },
  );

  testWidgets(
    'newer seek intent supersedes an older end EOF and pending Future',
    (tester) async {
      await saveRule(credits: true);
      await launch(tester);
      await tick(tester, 500);
      final oldGate = Completer<void>(), newGate = Completer<void>();
      backends.single
        ..seekGate = oldGate
        ..emitEndBeforeSeekGate = true;
      addTearDown(() {
        if (!oldGate.isCompleted) oldGate.complete();
        if (!newGate.isCompleted) newGate.complete();
      });
      await tester.tap(find.text('跳过片尾'));
      await tester.pump();
      expect(backends.single.snapshot.completed, isTrue);
      backends.single.seekGate = newGate;
      final latest = session.seek(const Duration(seconds: 20));
      await tester.pump();
      oldGate.complete();
      await tester.pump();
      await tester.pump();
      expect(
        backends.single.snapshot.completed,
        isTrue,
        reason: 'the backend still holds old EOF while the newer command waits',
      );
      expect(session.seeking, isTrue);
      expect(session.position, const Duration(seconds: 20));
      expect(session.completed, isFalse);
      expect(store.completions.receipt(session.account, '1'), isNull);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
      newGate.complete();
      await latest;
      await tester.pump();
      expect(backends.single.snapshot.completed, isFalse);
      expect(session.completed, isFalse);
      expect(session.position, const Duration(seconds: 20));
      expect(store.completions.receipt(session.account, '1'), isNull);
      expect(find.byKey(const Key('next-countdown')), findsNothing);
    },
  );
}
