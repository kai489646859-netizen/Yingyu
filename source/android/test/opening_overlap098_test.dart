import 'dart:async';
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
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'playback_test.dart' show FakeBackend;
import 'personal_features_test.dart' show featureEpisode;

class MetadataProbeApi extends EmbyClient {
  MetadataProbeApi({required super.client, required this.onDetail});
  final void Function(String) onDetail;
  @override
  Future<MediaItem> detail(String id, {Duration? requestTimeout}) {
    onDetail(id);
    return super.detail(id, requestTimeout: requestTimeout);
  }
}

void main() {
  for (final scenario in ['device', 'switch', 'denied', 'cancel', 'account']) {
    final switching = scenario == 'switch';
    final pendingDetail = scenario == 'cancel' || scenario == 'account';
    testWidgets(
      'accepted opening $scenario isolates metadata and never prefetches media',
      (tester) async {
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({});
          final value = AppStore(await SharedPreferences.getInstance());
          await value.log.setEnabled(false);
          return value;
        }))!;
        final calls = <String>[];
        final backends = <FakeBackend>[];
        final sessions = <PlaybackSession>[];
        var beforeDevice = false;
        final stopped = Completer<void>();
        final detail = Completer<void>();
        final api = MetadataProbeApi(
          onDetail: (id) => calls.add("begin:$id"),
          client: MockClient((r) async {
            final path = r.url.path;
            if (path.contains('Sessions/Playing')) {
              if (path.endsWith('Stopped')) {
                calls.add('stopped');
                await stopped.future;
              }
              return response('', 204);
            }
            if (path.endsWith('/PlaybackInfo')) {
              calls.add('route:${path.split('/')[path.split('/').length - 2]}');
              return response(jsonEncode(playbackData()), 200);
            }
            if (path.endsWith('/Episodes')) {
              return response(
                jsonEncode({
                  'Items': [featureEpisode('1').data, featureEpisode('2').data],
                }),
                200,
              );
            }
            final id = path.split('/').last;
            calls.add('detail:$id');
            if (pendingDetail) await detail.future;
            return response(jsonEncode(featureEpisode(id).data), 200);
          }),
        )..session = syntheticSession();
        PlaybackSession make(MediaItem item) {
          final backend = FakeBackend()..gate.complete();
          backends.add(backend);
          final s = PlaybackSession(
            api: api,
            store: store,
            item: item,
            backend: backend,
          );
          sessions.add(s);
          return s;
        }

        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(Device.channel, (call) async {
          if (call.method == 'focus') {
            beforeDevice = calls.contains('begin:1');
            return true;
          }
          if (call.method == 'levels') return {'brightness': .5, 'volume': .5};
          return null;
        });
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Future<void> settle() async {
          for (var i = 0; i < 15; i++) {
            await tester.runAsync(() => Future<void>.delayed(Duration.zero));
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        addTearDown(() async {
          if (!stopped.isCompleted) stopped.complete();
          if (!detail.isCompleted) detail.complete();
          await tester.pumpWidget(const SizedBox());
          await settle();
          api.close();
          store.log.dispose();
          store.dispose();
          messenger.setMockMethodCallHandler(Device.channel, null);
        });
        await tester.pumpWidget(
          MaterialApp(
            home: PlayerPage(
              createSession: () => make(featureEpisode('1')),
              createSessionForItem: make,
              allowNetwork: (_) async => scenario != 'denied',
            ),
          ),
        );
        await settle();
        if (scenario == 'denied') {
          expect(calls, isEmpty);
          expect(sessions.last.ready, isFalse);
          expect(sessions.last.error, contains('已取消流量播放'));
        } else if (pendingDetail) {
          expect(calls, contains('detail:1'));
          expect(calls.where((c) => c.startsWith('route:')), isEmpty);
          if (scenario == 'cancel') {
            await tester.pumpWidget(const SizedBox());
          } else {
            api.session = syntheticSession();
          }
          detail.complete();
          await settle();
          expect(calls.where((c) => c.startsWith('route:')), isEmpty);
          expect(backends.single.initial, isNull);
          expect(sessions.single.ready, isFalse);
          if (scenario == 'cancel') {
            expect(backends.single.disposed, isTrue);
          } else {
            expect(sessions.single.error, isNotNull);
          }
        } else if (!switching) {
          expect(
            beforeDevice,
            isTrue,
            reason: 'Fresh metadata begins before independent device setup.',
          );
          expect(sessions.last.ready, isTrue);
        } else {
          await settle();
          expect(sessions.last.ready, isTrue);
          expect(
            calls,
            isNot(contains('detail:2')),
            reason: 'No next-episode request before user intent.',
          );
          await tester.tap(find.byTooltip('下一集'));
          await settle();
          final earlyStopped = calls.contains('stopped');
          final earlyDetails = calls.where((c) => c == 'detail:2').length;
          final earlyRoutes = calls.contains('route:2');
          stopped.complete();
          await settle();
          expect(earlyStopped, isTrue);
          expect(
            earlyDetails,
            1,
            reason: 'Fresh target metadata must overlap old stopped report.',
          );
          expect(
            earlyRoutes,
            isFalse,
            reason:
                'Target media waits for saved progress and released old decoder.',
          );
          expect(sessions.last.item.id, '2');
          expect(sessions.last.ready, isTrue);
          expect(backends.first.disposed, isTrue);
          expect(calls.where((c) => c == 'detail:2').length, 1);
          for (var index = 0; index < 30; index++) {
            final previous = sessions.last.item.id == '2';
            await tester.tap(find.byTooltip(previous ? '上一集' : '下一集'));
            await settle();
            expect(sessions.last.ready, isTrue);
            expect(sessions.last.item.id, previous ? '1' : '2');
            expect(
              backends.take(backends.length - 1).every((b) => b.disposed),
              isTrue,
            );
            expect(backends.last.disposed, isFalse);
          }
          expect(backends.length, 32);
        }
      },
    );
  }
}
