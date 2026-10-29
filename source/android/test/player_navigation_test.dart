import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/backend.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class FittingBackend extends FakeBackend {
  BoxFit? lastFit;
  @override
  Widget view(BoxFit fit) {
    lastFit = fit;
    return super.view(fit);
  }
}

void main() {
  for (final failFirst in [false, true]) {
    testWidgets(
      'manual next saves progress, resets fit, prevents duplicates; failed factory retry=$failFirst',
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
        final progress = <String, int>{};
        final events = <String>[];
        var requests = 0;
        Json episode(String id) => {
          'Id': id,
          'Type': 'Episode',
          'Name': '合成$id',
          'SeriesId': 'series',
          'SeriesName': '合成剧集',
          'UserData': {'PlaybackPositionTicks': progress[id] ?? 0},
        };
        final api = EmbyClient(
          client: MockClient((request) async {
            requests++;
            final path = request.url.path;
            if (path.endsWith('/Episodes')) {
              return response(
                jsonEncode({
                  'Items': [episode('one'), episode('two')],
                }),
                200,
              );
            }
            if (path.endsWith('PlaybackInfo')) {
              events.add(
                'prepare:${path.split('/')[path.split('/').length - 2]}',
              );
              return response(jsonEncode(playbackData()), 200);
            }
            if (path.contains('Sessions/Playing')) {
              final body = jsonDecode(request.body) as Map;
              if (path.endsWith('/Stopped')) {
                progress[body['ItemId']] = body['PositionTicks'];
                events.add('stopped:${body['ItemId']}');
              }
              return response('', 204);
            }
            return response(jsonEncode(episode(path.split('/').last)), 200);
          }),
        )..session = syntheticSession();
        final backends = <FittingBackend>[];
        final sessions = <PlaybackSession>[];
        var fail = failFirst;
        PlaybackSession create(MediaItem item) {
          if (item.id == 'two' && fail) {
            fail = false;
            throw const AppFailure('合成初始化失败');
          }
          final backend = FittingBackend()..gate.complete();
          backends.add(backend);
          final session = PlaybackSession(
            api: api,
            store: store,
            item: item,
            backend: backend,
          );
          sessions.add(session);
          return session;
        }

        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              createSession: () => create(MediaItem(episode('one'))),
              createSessionForItem: create,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(sessions.single.ready, true);
        await sessions.single.setSpeed(2);
        expect(backends.first.lastFit, BoxFit.contain);
        expect(find.byIcon(Icons.aspect_ratio), findsNothing);
        await tester.tap(find.byTooltip('画面比例'));
        await tester.pumpAndSettle();
        expect(find.text('填充'), findsNothing);
        expect(backends.first.lastFit, BoxFit.cover);
        await backends.first.seek(const Duration(seconds: 72));
        await tester.pumpAndSettle();
        final beforeInfo = requests;
        await tester.tap(find.byTooltip('影片与播放信息'));
        await tester.pumpAndSettle();
        expect(find.text('影片与播放信息'), findsOneWidget);
        expect(requests, beforeInfo);
        expect(find.text('当前视频尺寸'), findsOneWidget);
        Navigator.of(tester.element(find.text('影片与播放信息'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('下一集'));
        await tester.pump();
        // Duplicate input during asynchronous close cannot open a second copy.
        await tester.tapAt(tester.getCenter(find.byTooltip('下一集')));
        for (var i = 0; i < 20 && sessions.length < 2; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          if (failFirst && find.text('重试').evaluate().isNotEmpty) {
            expect(find.text('合成初始化失败'), findsWidgets);
            await tester.tap(find.text('重试'));
            await tester.pump();
          }
        }
        expect(sessions.length, 2);
        expect(sessions.last.item.id, 'two');
        expect(sessions.last.speed, 2);
        expect(backends.last.speed, 2);
        expect(backends.first.disposed, true);
        expect(backends.last.lastFit, BoxFit.contain);
        expect(progress['one'], ticks(const Duration(seconds: 72)));
        expect(
          events.indexOf('stopped:one'),
          lessThan(events.indexOf('prepare:two')),
        );
        backends.last.updates.add(
          const PlaybackSnapshot(
            completed: true,
            duration: Duration(minutes: 90),
            position: Duration(minutes: 90),
          ),
        );
        await tester.pump();
        expect(sessions.length, 2); // no unrequested automatic next
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 20 && !backends.last.disposed; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        api.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
        expect(tester.takeException(), null);
      },
    );
  }
}
