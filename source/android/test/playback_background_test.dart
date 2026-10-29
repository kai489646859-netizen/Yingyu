import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/resume_button.dart';
import 'core_test.dart' show response, syntheticSession, playbackData;
import 'playback_test.dart' show FakeBackend;
import 'offline_settle.dart';

void main() {
  testWidgets(
    'playing for sixteen minutes pauses optional requests and timers but keeps progress reporting',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      syntheticImagePaths();
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        Device.channel,
        (call) async => call.method == 'playbackNetwork'
            ? 'unmetered'
            : call.method == 'focus'
            ? true
            : call.method == 'levels'
            ? {'brightness': .5, 'volume': .5}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          Device.channel,
          null,
        ),
      );
      final paths = <String>[];
      final movie = {
        'Id': 'movie',
        'Name': '合成影片',
        'Type': 'Movie',
        'RunTimeTicks': 54000000000,
        'UserData': {'PlaybackPositionTicks': 600000000},
      };
      final api = EmbyClient(
        client: MockClient((r) async {
          paths.add(r.url.path);
          if (r.url.path.contains('Sessions/Playing')) return response('', 204);
          if (r.url.path.endsWith('PlaybackInfo')) {
            return response(jsonEncode(playbackData()), 200);
          }
          if (r.url.path.endsWith('/Views')) {
            return response('{"Items":[]}', 200);
          }
          if (r.url.path.endsWith('/Resume') || r.url.path.endsWith('/Items')) {
            return response(
              jsonEncode({
                'Items': [movie],
                'TotalRecordCount': 1,
              }),
              200,
            );
          }
          return response(jsonEncode(movie), 200);
        }),
      )..session = syntheticSession();
      final store = AppStore(await SharedPreferences.getInstance());
      final backend = FakeBackend()..gate.complete();
      await tester.pumpWidget(
        MaterialApp(
          home: HomePage(
            api: api,
            store: store,
            createBackend: () => backend,
            logout: () async {},
          ),
        ),
      );
      await settleOffline(tester);
      expect(find.byType(ResumePlayButton), findsWidgets);
      tester
          .widget<ResumePlayButton>(find.byType(ResumePlayButton).first)
          .onPressed();
      await tester.pumpAndSettle();
      for (var i = 0; i < 10 && backend.plays == 0; i++) {
        await settleOffline(tester);
      }
      expect(find.byType(PlayerPage), findsOneWidget);
      expect(backend.plays, 1);
      expect(api.backgroundWork.paused, true);
      expect(PosterDemand.loadingPaused.value, true);
      final dynamic homeState = tester.state(
        find.byType(HomeDashboard, skipOffstage: false),
      );
      final libraryStates = tester
          .stateList(find.byType(LibraryPage, skipOffstage: false))
          .toList();
      expect(homeState.timer?.isActive ?? false, false);
      for (final dynamic state in libraryStates) {
        expect(state.timer?.isActive ?? false, false);
      }
      paths.clear();
      await tester.pump(const Duration(minutes: 16));
      await tester.pump();
      expect(
        paths.where((p) => !p.contains('/Sessions/Playing')),
        isEmpty,
        reason:
            'no catalogue, poster metadata, homepage or connection probes while playing',
      );
      expect(paths.any((p) => p.contains('/Sessions/Playing')), true);
      await tester.binding.handlePopRoute();
      for (
        var i = 0;
        i < 100 && find.byType(PlayerPage).evaluate().isNotEmpty;
        i++
      ) {
        // Exit includes real asynchronous persistence. Yield real time as well
        // as pumping fake frames, including under concurrent full-suite load.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(PlayerPage), findsNothing);
      expect(api.backgroundWork.paused, false);
      expect(PosterDemand.loadingPaused.value, false);
      expect(homeState.timer?.isActive ?? false, true);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(backend.dispose);
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
      expect(tester.takeException(), null);
    },
  );
}
