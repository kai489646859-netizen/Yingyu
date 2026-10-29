import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/ui/style.dart';
import 'cache_settings_test.dart' show fonts;
import 'phone_layout_test.dart' show setDisplay;

Future<void> captureTheme(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/controls106/previews/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await fonts();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test(
    'default and retired saved choices resolve to lilac; picker has four choices',
    () async {
      expect(AppAccent.available.map((v) => v.label), [
        '霞光紫',
        '海湾蓝',
        '宝石绿',
        '流金粉',
      ]);
      for (final old in [
        null,
        'teal',
        'blue',
        'purple',
        'titanium',
        'pearl',
        'unknown',
      ]) {
        final saved = <String, Object>{};
        if (old != null) saved['yingyu.accent.v1'] = old;
        SharedPreferences.setMockInitialValues(saved);
        final store = AppStore(await SharedPreferences.getInstance());
        expect(store.accent, AppAccent.lilac);
        expect(
          appTheme(Brightness.dark).colorScheme.primary,
          AppAccent.lilac.dark,
        );
        store.log.dispose();
        store.dispose();
      }
    },
  );
  for (final brightness in Brightness.values) {
    test('all theme accent text remains readable in $brightness', () {
      for (final choice in AppAccent.available) {
        final theme = appTheme(brightness, accentChoice: choice);
        final a = theme.colorScheme.primary.computeLuminance();
        for (final bg in [
          theme.scaffoldBackgroundColor,
          theme.colorScheme.surface,
        ]) {
          final b = bg.computeLuminance();
          final contrast = (a > b
              ? (a + .05) / (b + .05)
              : (b + .05) / (a + .05));
          expect(
            contrast,
            greaterThanOrEqualTo(4.5),
            reason: '${choice.name} $brightness',
          );
        }
      }
    });
    testWidgets('theme overview $brightness', (tester) async {
      setDisplay(tester, const Size(1080, 520));
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: key,
            child: Material(
              color: brightness == Brightness.dark
                  ? const Color(0xFF101216)
                  : const Color(0xFFF0F1F5),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: GridView.count(
                  crossAxisCount: 3,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 1.48,
                  children: [
                    for (final choice in AppAccent.available)
                      Theme(
                        data: appTheme(brightness, accentChoice: choice),
                        child: Builder(
                          builder: (context) => DecoratedBox(
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.surface,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        width: 22,
                                        height: 22,
                                        decoration: BoxDecoration(
                                          color: accentColor(context),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        choice.label,
                                        style: TextStyle(
                                          fontSize: 20,
                                          color: labelColor(context),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 22),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Icon(
                                        CupertinoIcons.house_fill,
                                        color: accentColor(context),
                                        size: 25,
                                      ),
                                      Icon(
                                        CupertinoIcons.heart_fill,
                                        color: accentColor(context),
                                        size: 24,
                                      ),
                                      Icon(
                                        CupertinoIcons.play_fill,
                                        color: accentColor(context),
                                        size: 24,
                                      ),
                                      const PlayerBattery(
                                        percent: 65,
                                        charging: true,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 18),
                                  LinearProgressIndicator(
                                    value: .62,
                                    color: accentColor(context),
                                    backgroundColor: accentColor(
                                      context,
                                    ).withValues(alpha: .16),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  const SizedBox(height: 15),
                                  Text(
                                    '继续观看',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: accentColor(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureTheme(tester, key, 'palette-${brightness.name}');
    });
  }
  for (final choice in AppAccent.available) {
    testWidgets('player controls and gesture feedback follow ${choice.name}', (
      tester,
    ) async {
      setDisplay(tester, const Size(844, 390));
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark, accentChoice: choice),
          home: RepaintBoundary(
            key: key,
            child: Material(
              color: const Color(0xFF22292C),
              child: Stack(
                children: [
                  PlayerChrome(
                    title: '合成剧 · 第 1 季 · 第 8 集',
                    visible: true,
                    ready: true,
                    playing: false,
                    episode: true,
                    position: const Duration(minutes: 12),
                    duration: const Duration(hours: 1),
                    onBack: () {},
                    onToggle: () {},
                    onSeekBack: () {},
                    onSeekForward: () {},
                    onMenu: () {},
                    onScrubStart: () {},
                    onScrub: (_) {},
                    onScrubEnd: (_) {},
                    onAudio: () {},
                    onInfo: () {},
                    onSubtitles: () {},
                    onRate: () {},
                    onFit: () {},
                    onEpisodes: () {},
                    onPrevious: () {},
                    onNext: () {},
                    status: PlayerStatusData(
                      time: DateTime(2026, 10, 20, 12, 6),
                      network: 'wifi',
                      batteryPercent: 65,
                      charging: true,
                    ),
                  ),
                  const Align(
                    alignment: Alignment(0, -.5),
                    child: PlaybackLevelFeedback(brightness: true, level: .65),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final icon = find.descendant(
        of: find.byTooltip('播放'),
        matching: find.byType(Icon),
      );
      expect(tester.widget<Icon>(icon).color, choice.dark);
      final slider = tester.widget<SliderTheme>(find.byType(SliderTheme));
      expect(slider.data.activeTrackColor, choice.dark);
      expect(find.text('65'), findsNothing);
      expect(tester.takeException(), isNull);
      await captureTheme(tester, key, 'player-${choice.name}');
    });
  }
}
