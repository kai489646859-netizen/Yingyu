import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';

void main() {
  for (final player in [false, true]) {
    testWidgets(
      'player=$player real popup barrier preserves the requested video visibility',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            home: Builder(
              builder: (context) => Scaffold(
                backgroundColor: Colors.orange,
                body: TextButton(
                  onPressed: () => showSurface<void>(
                    context,
                    (_) => SurfacePage(
                      title: 'Popup',
                      playerMenu: player,
                      child: const SettingsGroup(
                        children: [SettingsRow('Popup content')],
                      ),
                    ),
                    playerMenu: player,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final barrier = tester.widget<ModalBarrier>(
          find
              .byWidgetPredicate(
                (widget) => widget is ModalBarrier && widget.dismissible,
              )
              .last,
        );
        // Flutter omits the paint color for a fully transparent route barrier.
        expect(barrier.color?.a ?? 0, closeTo(player ? 0 : .4, .001));
        expect(barrier.dismissible, isTrue);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('surface-panel')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets(
      'player=$player panel keeps one background layer and opaque text',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark),
            home: Scaffold(
              backgroundColor: Colors.orange,
              body: SurfacePage(
                title: 'Panel',
                playerMenu: player,
                child: const SettingsGroup(children: [SettingsRow('Readable')]),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final panel = find.byKey(const Key('surface-panel'));
        final material = tester.widget<Material>(
          find.descendant(of: panel, matching: find.byType(Material)).first,
        );
        expect(material.color!.a, closeTo(player ? .8 : 1, .001));
        final group = find.byType(SettingsGroup);
        final cards = tester.widgetList<ColoredBox>(
          find.descendant(of: group, matching: find.byType(ColoredBox)),
        );
        expect(cards, isNotEmpty);
        expect(cards.every((box) => box.color.a == (player ? 0 : 1)), true);
        final text = tester.widget<Text>(find.text('Readable'));
        expect(text.style!.color!.a, 1);
        expect(
          find.ancestor(
            of: find.text('Readable'),
            matching: find.byType(Opacity),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'player background follows the selected theme at exactly eighty percent alpha',
    (tester) async {
      final colors = <Color>[];
      for (final accent in [
        AppAccent.emerald,
        AppAccent.blush,
        AppAccent.rose,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.dark, accentChoice: accent),
            home: const SurfacePage(
              title: 'Panel',
              playerMenu: true,
              child: SizedBox(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final material = tester.widget<Material>(
          find
              .descendant(
                of: find.byKey(const Key('surface-panel')),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(
          material.color,
          playerPanelColor(
            tester.element(find.byKey(const Key('surface-panel'))),
          ),
        );
        colors.add(material.color!);
        expect(material.color!.a, closeTo(.8, .001));
      }
      expect(colors.toSet(), hasLength(3));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
