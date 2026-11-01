import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/style.dart';

void main() {
  for (final action in ['release', 'cancel', 'reverse']) {
    testWidgets('entry animation remains continuous on early $action', (
      tester,
    ) async {
      var selected = 0;
      final calls = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) => Align(
                alignment: Alignment.bottomCenter,
                child: GlassNavigation(
                  index: selected,
                  onChanged: (i) {
                    calls.add(i);
                    set(() => selected = i);
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final first = tester.getCenter(find.byKey(const Key('navigation-tab-0')));
      final target = tester.getCenter(
        find.byKey(const Key('navigation-tab-2')),
      );
      final pill = find.byKey(const Key('navigation-glass-indicator'));
      final gesture = await tester.startGesture(target);
      await gesture.moveBy(const Offset(24, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final before = tester.getCenter(pill).dx;
      expect(before, allOf(greaterThan(first.dx), lessThan(target.dx + 24)));
      if (action == 'release') await gesture.up();
      if (action == 'cancel') await gesture.cancel();
      if (action == 'reverse') await gesture.moveTo(first);
      await tester.pump();
      expect(tester.getCenter(pill).dx, closeTo(before, .01));
      await tester.pump(const Duration(milliseconds: 200));
      if (action == 'reverse') {
        await gesture.up();
        await tester.pumpAndSettle();
      }
      expect(calls, action == 'release' ? [2] : isEmpty);
      expect(
        tester.getCenter(pill).dx,
        closeTo(action == 'release' ? target.dx : first.dx, .01),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
  for (final width in [412.0, 1280.0]) {
    testWidgets(
      'direct drag starts before long-press deadline and enters smoothly $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var selected = 0;
        final calls = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, set) => Align(
                  alignment: Alignment.bottomCenter,
                  child: GlassNavigation(
                    index: selected,
                    onChanged: (i) {
                      calls.add(i);
                      set(() => selected = i);
                    },
                  ),
                ),
              ),
            ),
          ),
        );
        final first = tester.getCenter(
          find.byKey(const Key('navigation-tab-0')),
        );
        final target = tester.getCenter(
          find.byKey(const Key('navigation-tab-2')),
        );
        final pill = find.byKey(const Key('navigation-glass-indicator'));
        final gesture = await tester.startGesture(target);
        await gesture.moveBy(const Offset(24, 0));
        await tester.pump();
        // Recognition starts from the currently painted position, not a teleport.
        expect(tester.getCenter(pill).dx, closeTo(first.dx, .01));
        await tester.pump(const Duration(milliseconds: 32));
        expect(tester.getCenter(pill).dx, greaterThan(first.dx + 1));
        expect(tester.getCenter(pill).dx, lessThan(target.dx + 24));
        expect(calls, isEmpty);
        final beforeRetarget = tester.getCenter(pill).dx;
        await gesture.moveBy(const Offset(17, 0));
        await tester.pump();
        expect(tester.getCenter(pill).dx, closeTo(beforeRetarget, .01));
        await tester.pump(const Duration(milliseconds: 160));
        expect(tester.getCenter(pill).dx, closeTo(target.dx + 41, .01));
        await gesture.moveBy(const Offset(-9, 0));
        await tester.pump();
        expect(tester.getCenter(pill).dx, closeTo(target.dx + 32, .01));
        expect(calls, isEmpty);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, [2]);
        expect(selected, 2);
        expect(tester.getCenter(pill).dx, closeTo(target.dx, .01));
        // An ordinary short tap must still select exactly once.
        await tester.tap(find.byKey(const Key('navigation-tab-1')));
        await tester.pumpAndSettle();
        expect(calls, [2, 1]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
