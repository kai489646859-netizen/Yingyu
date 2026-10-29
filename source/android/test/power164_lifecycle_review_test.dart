import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/library_events.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'core_test.dart' show response, syntheticSession, playbackData;
import 'playback_test.dart' show FakeBackend;
import 'offline_settle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'normal exit',
    'natural completion',
    'playback error',
    'opening error',
    'background and resume',
    'exit while backgrounded',
    'switch media',
    'decline mobile network',
  ]) {
    testWidgets('full HomePage restores optional work after $scenario', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      syntheticImagePaths();
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final paths = <String>[];
      final backends = <FakeBackend>[];
      final awake = <bool>[];
      var releases = 0;
      final movie = <String, dynamic>{
        'Id': 'movie',
        'Name': '合成影片',
        'Type': 'Movie',
        'RunTimeTicks': 54000000000,
        'UserData': {'PlaybackPositionTicks': 600000000},
      };
      final api = EmbyClient(
        client: MockClient((request) async {
          final path = request.url.path;
          paths.add(path);
          if (path.contains('Sessions/Playing')) return response('', 204);
          if (path.endsWith('PlaybackInfo')) {
            return response(
              scenario == 'opening error' ? '{}' : jsonEncode(playbackData()),
              scenario == 'opening error' ? 503 : 200,
            );
          }
          if (path.endsWith('/Views')) return response('{"Items":[]}', 200);
          if (path.endsWith('/Resume') || path.endsWith('/Items')) {
            return response(
              jsonEncode({
                'Items': [movie],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          return response(
            jsonEncode({...movie, 'Id': path.split('/').last}),
            200,
          );
        }),
      )..session = syntheticSession();
      final store = AppStore(await SharedPreferences.getInstance());
      await tester.runAsync(() => store.log.setEnabled(false));
      await store.setAutoNext(false);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        Device.channel,
        (call) async {
          if (call.method == 'playbackNetwork') {
            return scenario == 'decline mobile network'
                ? 'mobile'
                : 'unmetered';
          }
          if (call.method == 'focus') return true;
          if (call.method == 'levels') return {'brightness': .5, 'volume': .5};
          if (call.method == 'awake') awake.add(call.arguments as bool);
          if (call.method == 'release') releases++;
          return null;
        },
      );
      void resumeApp() {
        if (tester.binding.lifecycleState == AppLifecycleState.paused) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
        }
        if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }

      Future<void> cleanup() async {
        resumeApp();
        await tester.pumpWidget(const SizedBox());
        await settleOffline(tester);
        for (final backend in backends) {
          await tester.runAsync(backend.dispose);
        }
        api.close();
        await tester.runAsync(store.log.flush);
        store.log.dispose();
        store.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          Device.channel,
          null,
        );
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: HomePage(
              api: api,
              store: store,
              createBackend: () {
                final backend = FakeBackend()..gate.complete();
                backends.add(backend);
                return backend;
              },
              logout: () async {},
            ),
          ),
        );
        await settleOffline(tester);
        final dynamic home = tester.state(find.byType(HomePage));
        final dynamic dashboard = tester.state(find.byType(HomeDashboard));
        final play = home.play(MediaItem(movie), null, false) as Future<void>;
        await settleOffline(tester);
        if (scenario == 'decline mobile network') {
          await tester.tap(find.text('取消'));
          await settleOffline(tester);
          await play;
          expect(backends, isEmpty);
        } else {
          final dynamic player = tester.state(find.byType(PlayerPage));
          expect(home.playing, true);
          expect(api.backgroundWork.paused, true);
          expect(PosterDemand.loadingPaused.value, true);
          expect(dashboard.timer?.isActive ?? false, false);
          expect(home.connectionTimer?.isActive ?? false, false);
          for (final dynamic library in tester.stateList(
            find.byType(LibraryPage, skipOffstage: false),
          )) {
            expect(library.timer?.isActive ?? false, false);
          }
          if (scenario == 'opening error') {
            expect(player.session.error, isNotNull);
            expect(backends.single.plays, 0);
          } else {
            expect(player.session.ready, true);
            expect(backends.single.plays, 1);
            if (scenario == 'natural completion') {
              final backend = backends.single;
              backend.snapshot = const PlaybackSnapshot(
                position: Duration(minutes: 90),
                duration: Duration(minutes: 90),
                completed: true,
              );
              backend.updates.add(backend.snapshot);
              await settleOffline(tester);
              expect(player.session.completed, true);
              expect(awake.last, false);
            } else if (scenario == 'playback error') {
              backends.single.failures.add('合成播放错误');
              await settleOffline(tester);
              expect(player.session.error, isNotNull);
            } else if (scenario == 'switch media') {
              final switchJob =
                  player.switchEpisode(MediaItem({...movie, 'Id': 'next'}))
                      as Future<void>;
              await settleOffline(tester);
              await switchJob;
              expect(backends, hasLength(2));
              expect(backends.first.disposed, true);
              expect(backends.last.plays, 1);
              expect(player.session.item.id, 'next');
            } else if (scenario.contains('background')) {
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.inactive,
              );
              await tester.pump();
              expect(backends.single.snapshot.playing, true);
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.hidden,
              );
              tester.binding.handleAppLifecycleStateChanged(
                AppLifecycleState.paused,
              );
              await tester.pump();
              expect(backends.single.snapshot.playing, false);
              expect(awake.last, false);
              if (scenario == 'background and resume') {
                resumeApp();
                await tester.pump();
                expect(backends.single.snapshot.playing, false);
                await player.toggle();
                await tester.pump();
                expect(backends.single.snapshot.playing, true);
                expect(awake.last, true);
              }
            }
            paths.clear();
            await tester.pump(const Duration(minutes: 16));
            await tester.pump();
            expect(
              paths.where((p) => !p.contains('/Sessions/Playing')),
              isEmpty,
            );
            expect(api.backgroundWork.paused, true);
            if (scenario == 'normal exit') {
              expect(
                paths.any((p) => p.endsWith('/Sessions/Playing/Progress')),
                true,
              );
            }
          }
          // Leave through the production path including persistence, focus and orientation.
          unawaited(player.leave() as Future<void>);
          for (
            var i = 0;
            i < 100 && find.byType(PlayerPage).evaluate().isNotEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(releases, 1);
          if (scenario == 'exit while backgrounded') {
            expect(player.session.closed, true);
            expect(api.backgroundWork.paused, true);
            expect(PosterDemand.loadingPaused.value, true);
            expect(dashboard.timer?.isActive ?? false, false);
            // Android suppresses frames while paused; a popped route's exit
            // animation is removed after the app becomes visible again.
            resumeApp();
            await settleOffline(tester);
          }
          expect(find.byType(PlayerPage), findsNothing);
          await play;
        }
        expect(home.playing, false);
        expect(home.browse.paused, false);
        expect(home.homeFeed.paused, false);
        expect(api.backgroundWork.paused, false);
        expect(PosterDemand.loadingPaused.value, false);
        expect(dashboard.timer?.isActive ?? false, true);
        expect(home.connectionTimer?.isActive ?? false, true);
        paths.clear();
        final refresh = dashboard.refresh(force: true) as Future<void>;
        await settleOffline(tester);
        await refresh;
        expect(
          paths.any((p) => p.endsWith('/Resume')),
          true,
          reason:
              'Returning must restore usable manual refresh, not only an active timer',
        );
        expect(tester.takeException(), null);
      } finally {
        await cleanup();
      }
    });
  }

  testWidgets(
    'late optional socket closes during playback and reconnects on return',
    (tester) async {
      final api = EmbyClient()..session = syntheticSession();
      final first = Completer<LibraryEventChannel>();
      final streams = <StreamController<dynamic>>[];
      var connections = 0, closes = 0;
      LibraryEventChannel make() {
        final stream = StreamController<dynamic>.broadcast();
        streams.add(stream);
        return LibraryEventChannel(stream.stream, (_) {}, () async {
          closes++;
          await stream.close();
        });
      }

      final events = LibraryEvents(
        api,
        onChanges: (_, _) async {},
        connect: (_) async {
          connections++;
          return connections == 1 ? first.future : make();
        },
      );
      final owner = Object();
      events.setActive(true);
      await tester.pump();
      api.backgroundWork.pause(owner, true);
      first.complete(make());
      await tester.pump();
      expect(events.connected, false);
      expect(closes, 1);
      await tester.pump(const Duration(minutes: 16));
      expect(connections, 1);
      api.backgroundWork.pause(owner, false);
      await tester.pump();
      expect(events.connected, true);
      expect(connections, 2);
      events.dispose();
      await tester.pump();
      expect(closes, 2);
      api.close();
    },
  );
}
