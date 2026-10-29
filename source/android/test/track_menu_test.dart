import 'package:flutter/cupertino.dart';
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
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'package:yingyu/version.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show response, playbackData, syntheticSession;
import 'playback_test.dart' show FakeBackend;

class MenuBackend extends FakeBackend implements TrackStateBackend {
  @override
  String? selectedAudioId = '1';
  @override
  String? selectedSubtitleId = 'no';
  @override
  List<TrackOption> get audioTracks => [
    const TrackOption('auto', '自动 · 影片默认音轨', 'auto'),
    const TrackOption('no', '关闭音频', 'no'),
    for (final row in [
      ('1', 'eng', 'truehd', 8),
      ('2', 'jpn', 'dts', 6),
      ('3', 'chi', 'ac3', 6),
    ])
      TrackOption(
        row.$1,
        compactAudioTrackLabel(
          language: row.$2,
          codec: row.$3,
          channels: row.$4,
          channelLayout: row.$4 == 8 ? '7.1' : '5.1(side)',
        ),
        row.$1,
        language: row.$2,
        codec: row.$3,
      ),
  ];
  @override
  List<TrackOption> get subtitleTracks => [
    const TrackOption('auto', '自动 · 简体中文优先', 'auto'),
    const TrackOption('no', '关闭字幕', 'no'),
    for (final row in [
      ('1', 'chs', '简体中文'),
      ('2', 'chi', ''),
      ('3', 'eng', 'English'),
    ])
      TrackOption(
        row.$1,
        trackLabel(
          id: row.$1,
          language: row.$2,
          title: row.$3,
          codec: 'hdmv_pgs_subtitle',
        ),
        row.$1,
        language: row.$2,
        title: row.$3,
        codec: 'hdmv_pgs_subtitle',
      ),
  ];
  @override
  Future<void> audio(TrackOption track) async {
    selectedAudioId = track.id == 'auto' ? '1' : track.id;
    updates.add(snapshot);
  }

  @override
  Future<void> subtitle(TrackOption track) async {
    selectedSubtitleId = track.id;
    updates.add(snapshot);
  }
}

void main() {
  for (final (size, scale, accent) in [
    (const Size(412, 915), 1.0, AppAccent.blush),
    (const Size(915, 412), 1.0, AppAccent.rose),
    (const Size(1280, 800), 1.0, AppAccent.emerald),
    (const Size(320, 740), 1.6, AppAccent.lilac),
    (const Size(1024, 600), 1.0, AppAccent.amber),
  ]) {
    testWidgets(
      'anchored track menu and selected state at $size scale $scale, synthetic backend only',
      (tester) async {
        tester.view.physicalSize = size;
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
        for (final font in {
          'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
          'packages/cupertino_icons/CupertinoIcons':
              'packages/cupertino_icons/assets/CupertinoIcons.ttf',
        }.entries) {
          await (FontLoader(
            font.key,
          )..addFont(rootBundle.load(font.value))).load();
        }
        final fontPath = Platform.environment['YINGYU_TEST_FONT'];
        if (fontPath != null) {
          for (final name in [
            'Roboto',
            '.SF UI Text',
            '.SF UI Display',
            'CupertinoSystemText',
            'CupertinoSystemDisplay',
          ]) {
            final loader = FontLoader(name)
              ..addFont(
                Future.value(
                  ByteData.sublistView(File(fontPath).readAsBytesSync()),
                ),
              );
            await loader.load();
          }
        }
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        final requests = <String>[];
        final api = EmbyClient(
          client: MockClient((request) async {
            requests.add(request.url.path);
            if (request.url.path.endsWith('PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (request.url.path.contains('Sessions/Playing')) {
              return response('', 204);
            }
            return response(
              '{"Id":"movie","Type":"Movie","Name":"合成轨道展示"}',
              200,
            );
          }),
        )..session = syntheticSession();
        final backend = MenuBackend()..gate.complete();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          messenger.setMockMethodCallHandler(Device.channel, null);
        });
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme(Brightness.dark, accentChoice: accent),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: PlayerPage(createSession: () => session),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(backend.selectedSubtitleId, '1');
        expect(backend.selectedAudioId, '1');
        final infoIcon = find.descendant(
          of: find.byTooltip('影片与播放信息'),
          matching: find.byType(Icon),
        );
        expect(tester.widget<Icon>(infoIcon).color, accent.dark);
        final timelineTheme = tester
            .widget<SliderTheme>(
              find
                  .ancestor(
                    of: find.byKey(const Key('playback-timeline')),
                    matching: find.byType(SliderTheme),
                  )
                  .first,
            )
            .data;
        expect(timelineTheme.activeTrackColor, accent.dark);
        expect(timelineTheme.thumbColor, Colors.white);
        final opens = requests.where((p) => p.endsWith('PlaybackInfo')).length;
        final beforeQuality = List<String>.of(requests);
        final beforePosition = backend.snapshot.position;
        await tester.tap(find.byTooltip('画面比例'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(SelectionRow, '适应'), findsNothing);
        expect(find.widgetWithText(SelectionRow, '填充'), findsNothing);
        expect(find.byIcon(CupertinoIcons.check_mark), findsNothing);
        expect(find.byKey(const Key('surface-panel')), findsNothing);
        expect(
          tester.widget<PlayerChrome>(find.byType(PlayerChrome)).filled,
          true,
        );
        expect(requests, beforeQuality);
        expect(backend.snapshot.position, beforePosition);
        expect(backend.selectedAudioId, '1');
        expect(backend.selectedSubtitleId, '1');
        await tester.tap(find.byTooltip('播放器菜单'));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(SettingsRow, '音轨'), findsNothing);
        expect(find.widgetWithText(SettingsRow, '字幕'), findsNothing);
        expect(find.widgetWithText(SettingsRow, '播放倍速'), findsNothing);
        expect(find.widgetWithText(SettingsRow, '画质'), findsNothing);
        expect(find.widgetWithText(SettingsRow, '画面比例'), findsNothing);
        expect(find.text('片头片尾'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('音频'));
        await tester.pumpAndSettle();
        expect(find.text('英语 · TrueHD · 7.1 声道'), findsOneWidget);
        expect(find.text('日语 · DTS · 5.1 声道'), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.check_mark), findsNothing);
        final audioLabel = find.text('英语 · TrueHD · 7.1 声道');
        expect(tester.widget<Text>(audioLabel).maxLines, 1);
        expect(
          tester.widget<Text>(audioLabel).style!.color,
          accentColor(tester.element(audioLabel)),
        );
        expect(tester.takeException(), isNull);
        if (size.width == 1280) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final img = await boundary.toImage();
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/ui-previews/$appVersion-player-audio-menu.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            img.dispose();
          });
        }
        Navigator.of(tester.element(find.text('自动 · 影片默认音轨'))).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('字幕'));
        await tester.pumpAndSettle();
        expect(find.text('简中（PGS）'), findsOneWidget);
        expect(find.text('中文（PGS）'), findsOneWidget);
        expect(find.byIcon(CupertinoIcons.check_mark), findsNothing);
        final subtitleLabel = find.text('简中（PGS）');
        expect(tester.widget<Text>(subtitleLabel).maxLines, 1);
        expect(
          tester.widget<Text>(subtitleLabel).style!.color,
          accentColor(tester.element(subtitleLabel)),
        );
        if (size.width == 1280) {
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final img = await boundary.toImage();
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            await File(
              'build/ui-previews/$appVersion-player-subtitle-menu.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            img.dispose();
          });
        }
        await tester.ensureVisible(find.text('关闭字幕'));
        await tester.tap(find.text('关闭字幕'));
        await tester.pumpAndSettle();
        expect(backend.selectedSubtitleId, 'no');
        for (final label in ['音频', '字幕', '播放速度', '影片与播放信息']) {
          final trigger = find.byTooltip(label);
          expect(trigger, findsOneWidget);
          final anchor = tester.getRect(trigger);
          await tester.tap(trigger);
          await tester.pumpAndSettle();
          final panel = tester.getRect(find.byKey(const Key('surface-panel')));
          if (label == '影片与播放信息') {
            expect(panel.center.dx, closeTo(size.width / 2, .01));
            expect(panel.center.dy, closeTo(size.height / 2, .01));
          } else {
            expect(panel.bottom, closeTo(anchor.top - 4, .01));
            if (anchor.center.dx - panel.width / 2 >= 8 &&
                anchor.center.dx + panel.width / 2 <= size.width - 8) {
              expect(panel.center.dx, closeTo(anchor.center.dx, .01));
            }
          }
          expect(panel.left, greaterThanOrEqualTo(8));
          expect(panel.right, lessThanOrEqualTo(size.width - 8));
          if (size.width == 1280 && label == '音频') {
            // A layout change keeps the same menu, but follows the new button.
            tester.view.physicalSize = const Size(800, 1280);
            await tester.pumpAndSettle();
            final nextAnchor = tester.getRect(trigger);
            final nextPanel = tester.getRect(
              find.byKey(const Key('surface-panel')),
            );
            expect(nextPanel.bottom, closeTo(nextAnchor.top - 4, .01));
            tester.view.physicalSize = size;
            await tester.pumpAndSettle();
          }
          Navigator.of(
            tester.element(find.byKey(const Key('surface-panel'))),
          ).pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        expect(requests.where((p) => p.endsWith('PlaybackInfo')).length, opens);
        expect(backend.selectedAudioId, '1');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        store.log.dispose();
      },
    );
  }
}
