import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/player_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final entry in {
      'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      'packages/cupertino_icons/CupertinoIcons':
          'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    }.entries) {
      await (FontLoader(
        entry.key,
      )..addFont(rootBundle.load(entry.value))).load();
    }
    final font = Platform.environment['YINGYU_TEST_FONT'];
    if (font != null) {
      for (final name in [
        'Ahem',
        'Roboto',
        '.SF UI Text',
        '.SF UI Display',
        'CupertinoSystemText',
        'CupertinoSystemDisplay',
      ]) {
        await (FontLoader(name)..addFont(
              Future.value(ByteData.sublistView(File(font).readAsBytesSync())),
            ))
            .load();
      }
    }
  });
  test('episode heading and decimal speed retain exact values', () {
    expect(playbackRateText(1), '1.0×');
    expect(playbackRateText(2), '2.0×');
    expect(playbackRateText(1.25), '1.25×');
    expect(
      playbackTitle(
        MediaItem({
          'Type': 'Episode',
          'Name': '本集标题',
          'SeriesName': '剧名',
          'ParentIndexNumber': 2,
          'IndexNumber': 8,
        }),
      ),
      '剧名 · 第 2 季 · 第 8 集 · 本集标题',
    );
  });
  testWidgets(
    'horizontal battery distinguishes charging without changing status sampling',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: PlayerBattery(percent: 42, charging: false)),
        ),
      );
      final shape = tester.getSize(find.byKey(const Key('player-battery')));
      expect(shape.width, greaterThan(shape.height));
      expect(find.byKey(const Key('player-battery-charging')), findsNothing);
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: PlayerBattery(percent: 43, charging: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('player-battery-charging')), findsOneWidget);
      expect(find.text('43'), findsNothing);
    },
  );
  for (final size in [
    const Size(360, 780),
    const Size(844, 390),
    const Size(1280, 800),
  ]) {
    for (final episode in [false, true]) {
      testWidgets(
        'transport invokes ten-second actions with movie/episode layout $size $episode',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var back = 0, forward = 0;
          final capture = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              home: RepaintBoundary(
                key: capture,
                child: Material(
                  color: const Color(0xFF111516),
                  child: Stack(
                    children: [
                      PlayerChrome(
                        title: episode ? '合成剧 · 第 1 季 · 第 8 集 · 本集标题' : '合成电影',
                        visible: true,
                        ready: true,
                        playing: true,
                        position: const Duration(minutes: 12),
                        duration: const Duration(hours: 2),
                        episode: episode,
                        onBack: () {},
                        onToggle: () {},
                        onSeekBack: () => back++,
                        onSeekForward: () => forward++,
                        onMenu: () {},
                        onScrubStart: () {},
                        onScrub: (_) {},
                        onScrubEnd: (_) {},
                        onAudio: () {},
                        onInfo: () {},
                        status: PlayerStatusData(
                          time: DateTime(2026, 10, 20, 12, 6),
                          rxBytesPerSecond: 6.3 * 1024 * 1024,
                          network: 'wifi',
                          batteryPercent: 58,
                          charging: episode,
                        ),
                        onSubtitles: () {},
                        onRate: () {},
                        onFit: () {},
                        onEpisodes: episode ? () {} : null,
                        onPrevious: episode ? () {} : null,
                        onNext: episode ? () {} : null,
                      ),
                      const Align(
                        alignment: Alignment(0, -.5),
                        child: PlaybackLevelFeedback(
                          brightness: true,
                          level: .65,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('快退 10 秒'));
          await tester.tap(find.byTooltip('快进 10 秒'));
          expect(back, 1);
          expect(forward, 1);
          expect(
            find.byTooltip('下一集'),
            episode ? findsOneWidget : findsNothing,
          );
          expect(find.byTooltip('画面比例'), findsOneWidget);
          expect(find.byTooltip('播放器菜单'), findsOneWidget);
          expect(find.text('1.0×'), findsOneWidget);
          final rateBox = tester.getRect(find.byTooltip('播放速度'));
          final audioBox = tester.getRect(find.byTooltip('音频'));
          expect(rateBox.right, closeTo(audioBox.left, .01));
          expect(rateBox.center.dy, closeTo(audioBox.center.dy, .01));
          expect(audioBox.center.dx, greaterThan(size.width / 2));
          expect(find.textContaining('%'), findsNothing);
          expect(tester.takeException(), null);
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final img = await boundary.toImage();
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/play105/previews/${episode ? 'episode' : 'movie'}-${size.width.toInt()}x${size.height.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            img.dispose();
          });
        },
      );
    }
  }
}
