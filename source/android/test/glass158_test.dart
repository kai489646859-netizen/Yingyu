import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/playback/controls.dart';
import 'manual_refresh_test.dart' show RefreshFixture;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_settle.dart';
import 'offline_capture.dart';

void main() {
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'yingyu.visualStyle.v1': 'liquidGlass',
    });
  });
  for (final size in [
    const Size(390, 844),
    const Size(1280, 837),
    const Size(837, 1280),
  ]) {
    for (final brightness in Brightness.values) {
      for (final accent in AppAccent.available) {
        testWidgets(
          'retired glass restores readable settings and navigation $size $brightness ${accent.name}',
          (tester) async {
            setDisplay(tester, size);
            final f = RefreshFixture(await SharedPreferences.getInstance());
            addTearDown(f.dispose);
            await f.store.setAccent(accent);
            final boundary = GlobalKey();
            var selected = -1;
            await tester.pumpWidget(
              MaterialApp(
                theme: appTheme(
                  brightness,
                  accentChoice: accent,
                  visualStyle: f.store.visualStyle,
                ),
                home: RepaintBoundary(
                  key: boundary,
                  child: Scaffold(
                    body: SettingsPage(store: f.store, browse: f.repo),
                    bottomNavigationBar: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: SizedBox(
                          height: 68,
                          child: GlassNavigation(
                            index: 2,
                            onChanged: (i) => selected = i,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await settleOffline(tester);
            expect(f.store.visualStyle, VisualStyle.traditional);
            expect(
              find.byKey(const ValueKey('visual-style-setting')),
              findsNothing,
            );
            expect(find.byType(AdaptiveGlass), findsNothing);
            final nav = tester.getRect(
              find.byKey(const Key('phone-navigation')),
            );
            expect(nav.bottom, lessThanOrEqualTo(size.height));
            for (var i = 0; i < 4; i++) {
              final target = find.byKey(ValueKey('navigation-tab-$i'));
              expect(tester.getSize(target).height, greaterThanOrEqualTo(44));
              expect(tester.getSize(target).width, greaterThanOrEqualTo(44));
            }
            await tester.tap(find.byKey(const ValueKey('navigation-tab-0')));
            expect(selected, 0);
            await captureOffline(
              tester,
              boundary,
              'traditional160-${size.width.toInt()}-${brightness.name}-${accent.name}',
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
          },
        );
      }
    }
  }
  for (final size in [const Size(844, 390), const Size(1280, 837)]) {
    testWidgets('traditional player controls retain interactions $size', (
      tester,
    ) async {
      setDisplay(tester, size);
      var toggles = 0, scrubs = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(
            Brightness.dark,
            visualStyle: VisualStyle.liquidGlass,
          ),
          home: Scaffold(
            body: PlayerChrome(
              title: '合成播放器',
              visible: true,
              ready: true,
              playing: true,
              position: const Duration(minutes: 10),
              duration: const Duration(hours: 1),
              onBack: () {},
              onToggle: () => toggles++,
              onSeekBack: () {},
              onSeekForward: () {},
              onMenu: () {},
              onScrubStart: () => scrubs++,
              onScrub: (_) {},
              onScrubEnd: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdaptiveGlass), findsNothing);
      await tester.tap(find.byTooltip('暂停'));
      expect(toggles, 1);
      await tester.drag(find.byType(Slider), const Offset(50, 0));
      expect(scrubs, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
