import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/info.dart';
import 'package:yingyu/playback/media_facts.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'track_menu_test.dart' show MenuBackend;
import 'player_episode_menu_test.dart' show fonts;

class _Backend extends MenuBackend
    implements PlaybackFactsBackend, PlaybackResourceBackend {
  @override
  String discResourceType = 'ISO';
  int factReads = 0;
  PlaybackMediaFacts facts = const PlaybackMediaFacts({
    'vid': '1',
    'aid': '1',
    'video-format': 'h264',
    'video-bitrate': '25670000',
    'video-params/w': '1920',
    'video-params/h': '1080',
    'video-params/pixelformat': 'nv12',
    'container-fps': '23.976024',
    'video-params/primaries': 'bt.709',
    'video-params/gamma': 'bt.1886',
    'hwdec-current': 'mediacodec-copy',
    'audio-codec-name': 'truehd',
    'audio-bitrate': '3200000',
    'audio-params/samplerate': '48000',
    'audio-params/channels': '5.1(side)',
    'audio-out-params/channels': 'stereo',
  });
  @override
  PlaybackMediaFacts get mediaFacts {
    factReads++;
    return facts;
  }

  @override
  List<TrackOption> get audioTracks => [
    ...super.audioTracks,
    for (var i = 4; i <= 24; i++)
      TrackOption('$i', '测试长音轨名称 · DTS-HD MA · 7.1 · $i', '$i'),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late EmbyClient api;
  late PlaybackSession session;
  late _Backend backend;
  var requests = 0;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    requests = 0;
    api = EmbyClient(
      client: MockClient((r) async {
        if (!r.url.path.contains('Sessions/Playing')) requests++;
        return r.url.path.endsWith('PlaybackInfo')
            ? response(jsonEncode(playbackData()), 200)
            : r.url.path.contains('Sessions/Playing')
            ? response('', 204)
            : response('{"Id":"movie","Type":"Movie","Name":"合成播放信息"}', 200);
      }),
    )..session = syntheticSession();
    backend = _Backend()..gate.complete();
    session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    await session.open();
    session.route = PlaybackRoute(
      url: 'https://synthetic.invalid/file.iso',
      sourceId: 'source',
      sessionId: 'session',
      headers: {},
      streams: [],
      discKind: DiscKind.iso,
    );
  });
  tearDown(() async {
    await session.close();
    api.close();
    store.log.dispose();
    store.dispose();
  });
  testWidgets(
    'unknown resource container explains its scope while keeping current HDR facts',
    (tester) async {
      await fonts();
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      backend.discResourceType = '';
      backend.facts = PlaybackMediaFacts({
        ...backend.facts.values,
        'video-params/gamma': 'pq',
      });
      session.route = PlaybackRoute(
        url: 'https://synthetic.invalid/original',
        sourceId: 'source',
        sessionId: 'session',
        headers: {},
        streams: [],
      );
      final before = requests;
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(Brightness.dark),
            home: PlaybackInfoPage(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('资源类型'), 100);
      await tester.pumpAndSettle();
      expect(find.text('封装格式未识别 · HDR'), findsOneWidget);
      expect(find.text('当前播放未返回可识别的封装格式，视频编码和色彩信息仍单独显示。'), findsOneWidget);
      expect(requests, before);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/ui-previews/0.8.7-info-unknown-container.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'regression081 resource refreshes pending facts without network or idle reads',
    (tester) async {
      backend.facts = PlaybackMediaFacts({
        ...backend.facts.values,
        'current-tracks/video/dolby-vision-profile': '8',
      });
      final before = requests;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: PlaybackInfoPage(session: session),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('ISO · Dolby Vision · 杜比视界 Profile 8'), findsOneWidget);
      final reads = backend.factReads;
      await tester.pump(const Duration(seconds: 3));
      expect(backend.factReads, reads);
      backend.facts = PlaybackMediaFacts({
        ...backend.facts.values,
        'vid': '2',
        'current-tracks/video/dolby-vision-profile': '',
        'video-params/gamma': 'pq',
      });
      session.changed();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('ISO · HDR'), findsOneWidget);
      expect(find.textContaining('杜比视界 Profile 8'), findsNothing);
      expect(requests, before);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'regression081 more menu keeps custom settings without duplicate controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: PlayerMenu(
            session: session,
            fit: BoxFit.contain,
            onToggle: () {},
            onSeek: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SettingsRow, '片头片尾'), findsOneWidget);
      expect(find.widgetWithText(SettingsRow, '画面比例'), findsNothing);
      for (final text in ['播放倍速', '画质', '音轨', '字幕']) {
        expect(find.widgetWithText(SettingsRow, text), findsNothing);
      }
      expect(find.byTooltip('前进 10 秒'), findsNothing);
      expect(find.byTooltip('后退 10 秒'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'opaque ISO info uses live facts, labels estimates, and rejects an old audio selection',
    (tester) async {
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final font = Platform.environment['YINGYU_TEST_FONT'];
      for (final face in [
        'Roboto',
        '.SF UI Text',
        '.SF UI Display',
        'CupertinoSystemText',
        'CupertinoSystemDisplay',
      ]) {
        if (font != null) {
          await (FontLoader(face)..addFont(
                Future.value(
                  ByteData.sublistView(File(font).readAsBytesSync()),
                ),
              ))
              .load();
        }
      }
      for (final face in {
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
        'packages/cupertino_icons/CupertinoIcons':
            'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      }.entries) {
        await (FontLoader(
          face.key,
        )..addFont(rootBundle.load(face.value))).load();
      }
      final capture = GlobalKey();
      final before = requests;
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(Brightness.dark),
            home: PlaybackInfoPage(session: session),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, before);
      expect(find.text('资源类型'), findsOneWidget);
      expect(find.text('ISO'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('ISO'), 80);
      await tester.pumpAndSettle();
      expect(find.text('ISO').hitTestable(), findsOneWidget);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/ui-previews/$appVersion-info-resource.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.scrollUntilVisible(find.text('视频码率（当前估算）'), 150);
      await tester.pumpAndSettle();
      expect(find.text('25.67 Mbps'), findsOneWidget);
      expect(find.text('h264'), findsOneWidget);
      expect(find.text('1920 × 1080'), findsOneWidget);
      expect(find.text('服务器补充资料'), findsNothing);
      expect(find.textContaining('服务器标注'), findsNothing);
      final reads = backend.factReads;
      await tester.pump(const Duration(seconds: 3));
      expect(
        backend.factReads,
        reads,
        reason: 'The information panel has no polling timer',
      );
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/ui-previews/$appVersion-info-live-video.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.scrollUntilVisible(find.text('音频码率（当前估算）'), 160);
      await tester.pumpAndSettle();
      expect(find.text('3.20 Mbps'), findsOneWidget);
      expect(find.text('truehd'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('设备输出声道'), 120);
      await tester.pumpAndSettle();
      expect(find.text('5.1(side)'), findsOneWidget);
      expect(find.text('stereo'), findsOneWidget);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'build/ui-previews/$appVersion-info-live-audio.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.runAsync(
        () => session.chooseTrack(
          false,
          backend.audioTracks.firstWhere((t) => t.id == '2'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('5.1(side)'), findsNothing);
      expect(find.text('stereo'), findsNothing);
      expect(requests, before);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final size in [
    const Size(412, 915),
    const Size(640, 360),
    const Size(915, 412),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'compact audio panel retains final track and touch targets at $size with large text',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        PlayerMenuChoice? selected;
        var pane = 'audio';
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.5),
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await showSurface<PlayerMenuChoice>(
                    context,
                    (_) => PlayerMenu(
                      session: session,
                      initialPane: pane,
                      fit: BoxFit.contain,
                      onToggle: () {},
                      onSeek: (_) {},
                    ),
                    playerMenu: true,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final rect = tester.getRect(find.byKey(const Key('surface-panel')));
        expect(rect.height, lessThanOrEqualTo(420));
        expect(rect.width, lessThanOrEqualTo(size.width - 40));
        expect(rect.top, greaterThanOrEqualTo(16));
        expect(find.text('音轨'), findsNothing);
        expect(find.textContaining('长期记住'), findsNothing);
        expect(find.byTooltip('关闭'), findsNothing);
        expect(find.byTooltip('返回'), findsNothing);
        final last = find.text('测试长音轨名称 · DTS-HD MA · 7.1 · 24');
        await tester.scrollUntilVisible(last, 150, maxScrolls: 100);
        await tester.pumpAndSettle();
        expect(tester.getSize(last).height, greaterThan(16));
        expect(tester.widget<Text>(last).maxLines, 1);
        expect(tester.widget<Text>(last).overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
        await tester.tap(last);
        await tester.pumpAndSettle();
        expect((selected!.value as TrackOption).id, '24');
        pane = 'rate';
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final rateRect = tester.getRect(find.byKey(const Key('surface-panel')));
        expect(rateRect.width, lessThan(288));
        expect(find.text('播放倍速'), findsNothing);
        await tester.scrollUntilVisible(find.text('1.25×'), 80);
        await tester.pumpAndSettle();
        expect(tester.getSize(find.text('1.25×')).height, lessThan(40));
        await tester.tap(find.text('1.25×'));
        await tester.pumpAndSettle();
        expect(selected!.value, 1.25);
        pane = 'rate';
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final cancelRect = tester.getRect(
          find.byKey(const Key('surface-panel')),
        );
        expect(cancelRect.height, lessThanOrEqualTo(420));
        expect(find.text('播放倍速'), findsNothing);
        await tester.tapAt(const Offset(20, 40));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('surface-panel')), findsNothing);
        expect(selected, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
