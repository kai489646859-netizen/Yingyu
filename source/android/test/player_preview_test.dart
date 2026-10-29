// Render actual PlayerPage controls over a painted fixture; never load MPV.
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
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/page.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/picture_brightness.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'track_menu_test.dart' show MenuBackend;

class PreviewBackend extends MenuBackend
    implements
        VideoGeometryBackend,
        MediaNoticeBackend,
        PlaybackChapterBackend,
        SubtitleDelayBackend,
        SubtitlePositionBackend,
        PictureBrightnessBackend,
        DefaultSubtitlePositionBackend,
        ScopedSubtitlePositionBackend {
  @override
  SubtitlePositionScope subtitlePositionScope = SubtitlePositionScope.regular;
  @override
  void configureDiscSubtitlePosition(double? value) {}
  double subtitlePosition = 0;
  double pictureBrightness = 0;
  @override
  Future<double> readPictureBrightness({
    required bool Function() allowed,
  }) async => pictureBrightness;
  @override
  Future<double> setPictureBrightness(
    double value, {
    required bool Function() allowed,
  }) async => pictureBrightness = value;
  @override
  bool usesDefaultSubtitlePosition = true;
  @override
  Future<double> resetSubtitlePosition({
    required bool Function() allowed,
  }) async {
    if (!allowed()) throw const AppFailure('会话已改变');
    usesDefaultSubtitlePosition = true;
    return subtitlePosition = 0;
  }

  @override
  Future<double> readSubtitlePosition({
    required bool Function() allowed,
  }) async => subtitlePosition;
  @override
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  }) async {
    if (!allowed()) throw const AppFailure('会话已改变');
    usesDefaultSubtitlePosition = false;
    return subtitlePosition = value;
  }

  Duration delay = Duration.zero;
  @override
  Future<List<PlaybackChapter>> readChapters({
    required bool Function() allowed,
  }) async {
    if (!allowed()) throw const AppFailure('会话已改变');
    return const [
      PlaybackChapter(0, Duration.zero, '开场'),
      PlaybackChapter(1, Duration(minutes: 30), '远山来信'),
      PlaybackChapter(2, Duration(minutes: 70), '归途'),
    ];
  }

  @override
  Future<Duration> readSubtitleDelay({
    required bool Function() allowed,
  }) async => delay;
  @override
  Future<Duration> setSubtitleDelay(
    Duration value, {
    required bool Function() allowed,
  }) async => delay = value;
  @override
  String get sourceNotice => 'SDR · 已做色彩适配';
  @override
  double get videoAspectRatio => 16 / 9;
  @override
  Widget view(BoxFit fit) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: 2.39,
              child: CustomPaint(painter: _Frame()),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Frame extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, h),
          [
            const Color(0xFF102F41),
            const Color(0xFF78968D),
            const Color(0xFFBFBA9F),
          ],
          [0, .65, 1],
        ),
    );
    canvas.drawCircle(
      Offset(w * .7, h * .32),
      h * .1,
      Paint()..color = const Color(0xFFE5D3A4),
    );
    for (var n = 0; n < 5; n++) {
      final path = Path()
        ..moveTo(0, h * (.65 + n * .055))
        ..cubicTo(
          w * .23,
          h * (.03 + n * .1),
          w * .35,
          h * .94,
          w * .64,
          h * (.5 + n * .07),
        )
        ..quadraticBezierTo(w * .85, h * (.32 + n * .05), w, h * .7)
        ..lineTo(w, h)
        ..lineTo(0, h)
        ..close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Color.lerp(
            const Color(0xFF385A62),
            const Color(0xFF0A1A26),
            n / 4,
          )!,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

void main() {
  for (final spec in {
    'phone-portrait': const Size(412, 915),
    'phone-landscape': const Size(915, 412),
    'tablet-portrait': const Size(900, 1280),
    'tablet-landscape': const Size(1280, 800),
  }.entries) {
    testWidgets(
      'player appearance and menu transitions $spec without a native kernel',
      (tester) async {
        tester.view.physicalSize = spec.value;
        tester.view.display.size = spec.value;
        addTearDown(tester.view.display.resetSize);
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
        final fixedStatusTime = DateTime(
          2026,
          10,
          16,
          5,
          25,
        ).millisecondsSinceEpoch;
        var statusValues = <String, Object?>{
          'wallTimeMs': fixedStatusTime,
          'rxBytesPerSecond': 1572864.0,
          'network': 'wifi',
          'batteryPercent': 53,
          'charging': false,
        };
        messenger.setMockMethodCallHandler(
          PlayerStatusController.channel,
          (call) async => call.method == 'sample' ? statusValues : null,
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
            'CupertinoSystemText',
            'CupertinoSystemDisplay',
          ]) {
            await (FontLoader(name)..addFont(
                  Future.value(
                    ByteData.sublistView(File(fontPath).readAsBytesSync()),
                  ),
                ))
                .load();
          }
        }
        SharedPreferences.setMockInitialValues({});
        final store = AppStore(await SharedPreferences.getInstance());
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('PlaybackInfo')) {
              return response(jsonEncode(playbackData()), 200);
            }
            if (r.url.path.contains('Sessions/Playing')) {
              return response('', 204);
            }
            return response(
              '{"Id":"fixture","Type":"Movie","Name":"远山来信","RunTimeTicks":76800000000,"UserData":{"PlaybackPositionTicks":25380000000}}',
              200,
            );
          }),
        )..session = syntheticSession();
        final backend = PreviewBackend()..gate.complete();
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'fixture', 'Name': '远山来信'}),
          backend: backend,
        );
        final capture = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme(Brightness.dark),
              home: PlayerPage(createSession: () => session),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Future<void> shot(String page) async {
          expect(tester.takeException(), isNull);
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final img = await boundary.toImage();
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
              'build/ui-previews/$appVersion-${spec.key}-player-$page.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            img.dispose();
          });
        }

        for (final gesture in {'brightness': .2, 'volume': .8}.entries) {
          final drag = await tester.startGesture(
            Offset(spec.value.width * gesture.value, spec.value.height * .5),
          );
          await drag.moveBy(const Offset(0, -40));
          await drag.moveBy(const Offset(0, -35));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 220));
          expect(find.byKey(const Key('source-notice')), findsOneWidget);
          expect(
            find.byKey(ValueKey('${gesture.key}-level-feedback')),
            findsOneWidget,
          );
          await shot('source-with-${gesture.key}');
          await drag.up();
          await tester.pump();
        }
        final earlyHold = await tester.startGesture(
          Offset(spec.value.width * .5, spec.value.height * .5),
        );
        await tester.pump(const Duration(milliseconds: 650));
        expect(find.byKey(const Key('source-notice')), findsOneWidget);
        expect(find.text('3倍速'), findsOneWidget);
        await shot('source-with-held-speed');
        await earlyHold.up();
        await backend.seek(const Duration(minutes: 42, seconds: 18));
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        await shot('hidden');
        await tester.tapAt(Offset(spec.value.width / 2, spec.value.height / 2));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        // Whole viewport gesture, including left and right letterbox margins.
        final held = await tester.startGesture(
          Offset(spec.value.width * .2, spec.value.height * .4),
        );
        await tester.pump(const Duration(milliseconds: 650));
        await tester.pump(const Duration(milliseconds: 200));
        expect(session.speed, 3);
        await shot('held-speed');
        await held.up();
        await tester.pumpAndSettle();
        final level = await tester.startGesture(
          Offset(spec.value.width * .2, spec.value.height * .4),
        );
        await level.moveBy(const Offset(0, -60));
        await tester.pump();
        await level.moveBy(const Offset(0, -30));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 220));
        expect(
          find.byKey(const Key('brightness-level-feedback')),
          findsOneWidget,
        );
        await shot('brightness-feedback');
        await level.up();
        await tester.pumpAndSettle();
        expect(find.byTooltip('播放器菜单').hitTestable(), findsOneWidget);
        await shot('controls');
        if (spec.key.endsWith('landscape')) {
          await shot('status-wifi');
          statusValues = {
            'wallTimeMs': fixedStatusTime,
            'rxBytesPerSecond': 65536.0,
            'network': 'cellular',
            'batteryPercent': 12,
            'charging': true,
          };
          final dynamic state = tester.state(find.byType(PlayerPage));
          await state.playerStatus.sample();
          await tester.pumpAndSettle();
          await shot('status-cellular-charging');
          for (final percent in [20, 21]) {
            // Each extra preview needs the controls to remain visible before
            // the existing lock/unlock interaction sequence.
            state.scheduleHide();
            statusValues = {
              ...statusValues,
              'batteryPercent': percent,
              'charging': false,
            };
            await state.playerStatus.sample();
            await tester.pumpAndSettle();
            await shot('status-battery-$percent');
          }
          statusValues = {'wallTimeMs': fixedStatusTime};
          await state.playerStatus.sample();
          await tester.pumpAndSettle();
          await shot('status-unknown');
          await tester.tap(find.byTooltip('锁定屏幕'));
          await tester.pumpAndSettle();
          await shot('unlock-only');
          await tester.pump(const Duration(milliseconds: 5300));
          await tester.pumpAndSettle();
          await shot('screen-locked');
          await tester.tapAt(
            Offset(spec.value.width / 2, spec.value.height / 2),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('解锁屏幕'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('影片与播放信息'));
        await tester.pumpAndSettle();
        await shot('info');
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('播放器菜单'));
        await tester.pumpAndSettle();
        final moreTrigger = tester.getCenter(find.byTooltip('播放器菜单'));
        await shot('menu');
        expect(find.text('播放倍速'), findsNothing);
        expect(find.text('片头片尾'), findsOneWidget);
        expect(tester.widget<Text>(find.text('片头片尾')).maxLines, 1);
        expect(find.text('画面比例'), findsNothing);
        if (spec.key == 'phone-portrait' || spec.key == 'tablet-landscape') {
          await tester.tap(find.text('章节选择'));
          await tester.pumpAndSettle();
          await shot('chapters');
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('播放器菜单'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('字幕延迟'));
          await tester.pumpAndSettle();
          await shot('subtitle-delay');
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('播放器菜单'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('字幕位置'));
          await tester.pumpAndSettle();
          await shot('subtitle-position');
          await tester.tap(find.text('上移 5%'));
          await tester.pumpAndSettle();
          expect(backend.subtitlePosition, 5);
          await shot('subtitle-position-raised');
          await tester.tap(find.text('恢复默认位置'));
          await tester.pumpAndSettle();
          expect(backend.usesDefaultSubtitlePosition, true);
          expect(find.text('默认 · 画面下沿'), findsOneWidget);
          await shot('subtitle-position-reset');
          backend.subtitlePositionScope = SubtitlePositionScope.discEmbedded;
          session.changed();
          await tester.pumpAndSettle();
          expect(find.text('默认 · 原盘字幕排版'), findsOneWidget);
          await shot('disc-subtitle-position');
          await tester.tap(find.text('上移 5%'));
          await tester.pumpAndSettle();
          expect(backend.subtitlePosition, 5);
          await shot('disc-subtitle-position-adjusted');
          await tester.tap(find.text('恢复默认位置'));
          await tester.pumpAndSettle();
          expect(find.text('默认 · 原盘字幕排版'), findsOneWidget);
          backend.subtitlePositionScope = SubtitlePositionScope.regular;
          session.changed();
          await tester.pumpAndSettle();
          await tester.tapAt(moreTrigger);
          await tester.pumpAndSettle();
          expect(find.text('当前位置'), findsNothing);
          await tester.tap(find.byTooltip('播放器菜单'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('画面明暗'));
          await tester.pumpAndSettle();
          await shot('picture-brightness-original');
          await tester.tap(find.text('轻度提亮'));
          await tester.pumpAndSettle();
          expect(backend.pictureBrightness, 5);
          await shot('picture-brightness-light');
          await tester.tapAt(moreTrigger);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('播放器菜单'));
          await tester.pumpAndSettle();
        }
        // The visible three-dot trigger closes an expanded root panel too.
        await tester.tapAt(moreTrigger);
        await tester.pumpAndSettle();
        expect(find.text('播放器菜单'), findsNothing);
        await tester.tap(find.byTooltip('播放器菜单'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('播放速度'));
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byKey(const Key('surface-panel'))).width,
          lessThan(230),
        );
        await shot('rate');
        final rateScroll = find.descendant(
          of: find.byKey(const ValueKey('rate')),
          matching: find.byType(Scrollable),
        );
        double contentTop(String text) =>
            tester.getTopLeft(find.text(text)).dy +
            tester.state<ScrollableState>(rateScroll).position.pixels;
        final three = contentTop('3.0×');
        // A short phone landscape panel must scroll to the lowest rate.
        await tester.scrollUntilVisible(
          find.text('0.5×'),
          80,
          scrollable: rateScroll,
        );
        await tester.pumpAndSettle();
        expect(three, lessThan(contentTop('0.5×')));
        expect(find.text('0.5×').hitTestable(), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('1.25×'),
          -80,
          scrollable: rateScroll,
        );
        await tester.pumpAndSettle();
        expect(find.text('1.25×'), findsOneWidget);
        await tester.ensureVisible(find.text('1.5×'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('1.5×'));
        await tester.pumpAndSettle();
        expect(session.speed, 1.5);
        expect(backend.speed, 1.5);
        expect(backend.plays, 1);
        if (find.byKey(const Key('surface-panel')).evaluate().isNotEmpty) {
          await tester.tapAt(const Offset(5, 5));
          await tester.pumpAndSettle();
        }
        final dynamic pageState = tester.state(find.byType(PlayerPage));
        if (pageState.controls as bool) {
          await tester.tapAt(
            Offset(spec.value.width / 2, spec.value.height * .35),
          );
          await tester.pump(const Duration(milliseconds: 400));
        }
        backend.snapshot = PlaybackSnapshot(
          position: backend.snapshot.position,
          duration: backend.snapshot.duration,
          playing: true,
          buffering: true,
        );
        backend.updates.add(backend.snapshot);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(pageState.controls, false);
        expect(find.text('正在缓冲'), findsOneWidget);
        await shot('buffering-hidden-controls');
        backend.snapshot = PlaybackSnapshot(
          position: backend.snapshot.position,
          duration: backend.snapshot.duration,
          playing: true,
        );
        backend.updates.add(backend.snapshot);
        await tester.pumpAndSettle();
        final duration = backend.snapshot.duration;
        await session.seek(duration - const Duration(seconds: 1));
        backend.snapshot = PlaybackSnapshot(
          position: duration,
          duration: duration,
          completed: true,
        );
        backend.updates.add(backend.snapshot);
        await tester.pumpAndSettle();
        expect(find.text('影片已播放完'), findsOneWidget);
        final connectionNotice = find.byKey(
          const Key('playback-connection-notice'),
        );
        if (connectionNotice.evaluate().isNotEmpty) {
          expect(
            tester
                .getRect(find.byKey(const Key('playback-end-replay')))
                .overlaps(tester.getRect(connectionNotice)),
            false,
            reason:
                'A truthful progress warning must not cover the replay action',
          );
        }
        await shot('completed-movie');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        store.log.dispose();
        messenger.setMockMethodCallHandler(Device.channel, null);
        messenger.setMockMethodCallHandler(
          PlayerStatusController.channel,
          null,
        );
      },
    );
  }
}
