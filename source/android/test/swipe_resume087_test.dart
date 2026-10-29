import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/app.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/swipe_pages.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'offline_settle.dart';
import 'playback_test.dart' show FakeBackend;
import 'poster_test.dart' show RecordingCache;

class _FailedBackend extends FakeBackend {
  @override
  Future<void> open(PlaybackRoute route, Duration start) async {
    throw const AppFailure('合成播放打开失败');
  }
}

void main() {
  for (final cancelPermission in [true, false]) {
    testWidgets(
      'main tabs recover after ${cancelPermission ? 'cancelling playback permission' : 'leaving a failed player'} and covered layout changes',
      (tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        syntheticImagePaths();
        final previousPoster = posterCache, previousArtwork = artworkCache;
        posterCache = RecordingCache();
        artworkCache = RecordingCache();
        addTearDown(() {
          posterCache = previousPoster;
          artworkCache = previousArtwork;
        });
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          Device.channel,
          (call) async => switch (call.method) {
            'playbackNetwork' => cancelPermission ? 'mobile' : 'unmetered',
            'focus' => true,
            'levels' => {'brightness': .5, 'volume': .5},
            _ => null,
          },
        );
        addTearDown(
          () => messenger.setMockMethodCallHandler(Device.channel, null),
        );
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        await store.saveSession(syntheticSession());
        final movie = <String, dynamic>{
          'Id': 'movie',
          'Type': 'Movie',
          'Name': '合成影片',
          'RunTimeTicks': 54000000000,
          'UserData': {'PlaybackPositionTicks': 600000000},
        };
        final api = EmbyClient(
          client: MockClient((request) async {
            final path = request.url.path;
            if (path.endsWith('/Users/synthetic-user')) {
              return response('{"Id":"synthetic-user"}', 200);
            }
            if (path.endsWith('/Resume')) {
              return response(
                jsonEncode({
                  'Items': [movie],
                }),
                200,
              );
            }
            if (path.endsWith('/movie')) {
              return response(jsonEncode(movie), 200);
            }
            if (path.endsWith('/PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (path.contains('Sessions/Playing')) return response('', 204);
            return response('{"Items":[]}', 200);
          }),
        );
        var created = 0;
        await tester.pumpWidget(
          YingyuApp(
            api: api,
            store: store,
            backendFactory: () {
              created++;
              return _FailedBackend();
            },
          ),
        );
        await settleOffline(tester);
        await tester.tap(find.byKey(const ValueKey('resume-play-movie')));
        await settleOffline(tester);
        if (cancelPermission) {
          expect(find.text('正在使用移动数据'), findsOneWidget);
        } else {
          expect(find.byType(PlayerPage), findsOneWidget);
          expect(find.textContaining('合成播放打开失败'), findsWidgets);
        }
        tester.view.physicalSize = const Size(420, 915);
        await tester.pump();
        await tester.pump();
        expect(
          tester
              .widget<SwipePages>(find.byType(SwipePages, skipOffstage: false))
              .enabled,
          isFalse,
        );
        if (cancelPermission) {
          await tester.tap(find.text('取消'));
        } else {
          await tester.binding.handlePopRoute();
        }
        await settleOffline(tester);
        expect(find.byType(PlayerPage), findsNothing);
        await tester.dragFrom(const Offset(360, 30), const Offset(-300, 0));
        await settleOffline(tester);
        expect(
          tester.widget<GlassNavigation>(find.byType(GlassNavigation)).index,
          1,
        );
        expect(created, cancelPermission ? 0 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        api.close();
        store.log.dispose();
        store.dispose();
      },
    );
  }
}
