import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/personal_sync.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/adjustment_panels.dart';
import 'package:yingyu/playback/picture_brightness.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';
import 'package:yingyu/ui/personal_status_page.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'track_menu_test.dart' show MenuBackend;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';
import 'package:flutter/cupertino.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'subtitle_layout104_test.dart' show PendingSubtitleBackend104;

class ColorBackend104 extends MenuBackend
    implements PictureBrightnessBackend, ShadowEnhancementBackend {
  double gamma = 0;
  @override
  double shadowEnhancement = 0;
  @override
  Future<double> readPictureBrightness({
    required bool Function() allowed,
  }) async => gamma;
  @override
  Future<double> setPictureBrightness(
    double value, {
    required bool Function() allowed,
  }) async => gamma = value;
  @override
  Future<double> setShadowEnhancement(
    double value, {
    required bool Function() allowed,
  }) async => shadowEnhancement = value;
}

void main() {
  testWidgets(
    'authored reset waits quietly for geometry and enables the slider at the actual position',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final api = EmbyClient(
        client: MockClient((_) async => throw StateError('No network allowed')),
      )..session = syntheticSession();
      final backend = PendingSubtitleBackend104()
        ..scope = SubtitlePositionScope.discEmbedded;
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      session.configureSubtitleViewport(phone: false);
      session.ready = true;
      session.loading = false;
      await session.setSubtitlePosition(35);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await session.close();
        api.close();
        store.log.dispose();
        store.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: SubtitlePositionMenu(session: session, onBack: () {}),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('恢复默认位置'));
      await tester.pump();
      await tester.pump();
      expect(find.text('等待字幕出现，出现后即可调整'), findsOneWidget);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      final slider = find.byKey(const Key('subtitle-position-slider'));
      expect(tester.widget<CupertinoSlider>(slider).onChanged, isNull);
      backend.geometryReady = true;
      session.changed();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.widget<CupertinoSlider>(slider).value, 18.5);
      expect(tester.widget<CupertinoSlider>(slider).onChanged, isNotNull);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    },
  );
  for (final size in [
    const Size(320, 740),
    const Size(915, 412),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'real played page groups loaded episodes and keeps raw pagination at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        syntheticImagePaths();
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        await fonts();
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        final requests = <Uri>[];
        final opened = <MediaItem>[];
        final entries = [
          for (var i = 1; i <= 12; i++)
            {
              'Id': 'episode$i',
              'Type': 'Episode',
              'Name': '第 $i 集',
              'SeriesId': 'series',
              'SeriesName': '合成剧',
              'IndexNumber': i,
              'ParentIndexNumber': 1,
              'UserData': {'Played': true},
            },
          {
            'Id': 'movie',
            'Type': 'Movie',
            'Name': '合成电影',
            'UserData': {'Played': true},
          },
        ];
        final api = EmbyClient(
          client: MockClient((r) async {
            requests.add(r.url);
            expect(r.method, 'GET');
            expect(r.url.queryParameters['Filters'], 'IsPlayed');
            final start = int.parse(r.url.queryParameters['StartIndex']!);
            return response(
              jsonEncode({
                'Items': entries.skip(start).take(start == 0 ? 10 : 3).toList(),
                'TotalRecordCount': 13,
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        final sync = PersonalSync(api, store.personal);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await settleOffline(tester);
          sync.dispose();
          api.close();
          store.log.dispose();
          store.dispose();
        });
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: appTheme(Brightness.light),
              home: PersonalStatusPage(
                sync: sync,
                list: PersonalList.played,
                onItem: (item) async {
                  opened.add(item);
                },
              ),
            ),
          ),
        );
        await settleOffline(tester);
        expect(
          requests.length,
          1,
          reason: 'Grouping must not automatically drain every server page.',
        );
        await tester.tap(find.text('加载更多记录'));
        await settleOffline(tester);
        for (
          var i = 0;
          i < 5 &&
              !requests.any((r) => r.queryParameters['StartIndex'] == '10');
          i++
        ) {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -500),
          );
          await settleOffline(tester);
        }
        expect(
          requests.any((r) => r.queryParameters['StartIndex'] == '10'),
          true,
        );
        expect(find.text('合成剧'), findsOneWidget);
        expect(find.text('合成电影'), findsOneWidget);
        expect(find.textContaining('2 部'), findsOneWidget);
        expect(find.textContaining('13 条已看记录'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await captureOffline(
          tester,
          capture,
          'played-group104-${size.width.toInt()}',
        );
        await tester.tap(find.text('合成剧'));
        await settleOffline(tester);
        expect(opened.single.id, 'series');
        expect(opened.single.series, true);
        expect(object(opened.single.data['UserData'])['Played'], isNull);
        expect(requests.every((r) => !r.path.contains('PlaybackInfo')), true);
      },
    );
    testWidgets(
      'brightness and shadow controls are independent and default off at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await fonts();
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        final api = EmbyClient(
          client: MockClient(
            (_) async => throw StateError('No network allowed'),
          ),
        )..session = syntheticSession();
        final backend = ColorBackend104();
        final session =
            PlaybackSession(
                api: api,
                store: store,
                item: MediaItem({'Id': 'movie'}),
                backend: backend,
              )
              ..ready = true
              ..loading = false;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await session.close();
          api.close();
          store.log.dispose();
          store.dispose();
        });
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              theme: appTheme(Brightness.dark),
              home: PictureBrightnessMenu(session: session, onBack: () {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('整体亮度增强'), findsOneWidget);
        expect(find.text('暗部增强'), findsOneWidget);
        expect(backend.gamma, 0);
        expect(backend.shadowEnhancement, 0);
        await captureOffline(
          tester,
          capture,
          'shadow-controls104-${size.width.toInt()}',
        );
        await tester.scrollUntilVisible(
          find.text('中度'),
          80,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('中度'));
        await tester.pumpAndSettle();
        expect(backend.shadowEnhancement, .5);
        expect(backend.gamma, 0);
        await tester.scrollUntilVisible(
          find.text('轻度提亮'),
          -80,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('轻度提亮'));
        await tester.pumpAndSettle();
        expect(backend.gamma, 5);
        expect(backend.shadowEnhancement, .5);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
