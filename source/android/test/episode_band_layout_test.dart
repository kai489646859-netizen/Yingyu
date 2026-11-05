import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/episode_band_picker.dart';
import 'package:yingyu/ui/surface.dart';

void main() {
  for (final size in [
    const Size(360, 800),
    const Size(800, 360),
    const Size(1024, 768),
    const Size(768, 1024),
  ]) {
    for (final bottom in [false, true]) {
      for (final count in [1, 20]) {
        testWidgets('anchored range $count $size bottom=$bottom', (
          tester,
        ) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          int? picked;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SafeArea(
                  child: Align(
                    alignment: bottom
                        ? Alignment.bottomRight
                        : Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: EpisodeBandButton(
                        key: const Key('trigger'),
                        id: 'ranges',
                        count: count,
                        selected: count - 1,
                        label: (i) => i == 0 ? '1–8' : 'range $i',
                        onSelected: (i) => picked = i,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          final anchor = tester.getRect(find.byKey(const Key('trigger')));
          await tester.tap(find.byKey(const Key('trigger')));
          await tester.pumpAndSettle();
          final panel = tester.getRect(
            find.byKey(const Key('anchored-menu-panel')),
          );
          expect(panel.height, lessThanOrEqualTo(count * 60.0));
          expect(panel.left, greaterThanOrEqualTo(8));
          expect(panel.right, lessThanOrEqualTo(size.width - 8));
          expect(panel.top, greaterThanOrEqualTo(8));
          expect(panel.bottom, lessThanOrEqualTo(size.height - 8));
          expect(
            bottom ? panel.bottom : panel.top,
            closeTo(bottom ? anchor.top : anchor.bottom, .1),
          );
          expect(panel.right, closeTo(anchor.right, .1));
          await tester.tap(
            find.text(count == 1 ? '1–8' : 'range ${count - 1}'),
          );
          await tester.pumpAndSettle();
          expect(picked, count - 1);
          expect(tester.takeException(), isNull);
          await tester.tap(find.byKey(const Key('trigger')));
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(5, 200));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('anchored-menu-panel')), findsNothing);
        });
      }
    }
  }

  for (final size in [
    const Size(360, 800),
    const Size(800, 360),
    const Size(1024, 768),
  ]) {
    for (final count in [1, 3, 20]) {
      testWidgets(
        'range menu fits $count rows in $size and returns selection',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          int? selected;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      selected = await showSurface<int>(
                        context,
                        (_) => EpisodeBandPicker(
                          count: count,
                          selected: 0,
                          label: (i) => i == 0 ? '1–8' : 'range $i',
                        ),
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
          final rect = tester.getRect(
            find.byKey(const Key('selection-menu-panel')),
          );
          expect(rect.height, lessThanOrEqualTo(count * 60.0));
          expect(rect.top, greaterThanOrEqualTo(16));
          expect(rect.bottom, lessThanOrEqualTo(size.height - 16));
          if (count > 6) {
            await tester.scrollUntilVisible(
              find.text('range ${count - 1}'),
              150,
              scrollable: find.byType(Scrollable),
            );
            await tester.tap(find.text('range ${count - 1}'));
          } else {
            await tester.tap(find.text('1–8'));
          }
          await tester.pumpAndSettle();
          expect(selected, count > 6 ? count - 1 : 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
