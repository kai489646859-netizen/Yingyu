import 'dart:ui' show SemanticsAction;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/style.dart';

void main() {
  for (final width in [412.0, 1280.0]) {
    testWidgets(
      'stationary press previews immediately and releases once $width',
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
        final last = tester.getCenter(
          find.byKey(const Key('navigation-tab-3')),
        );
        final pill = find.byKey(const Key('navigation-glass-indicator'));
        final gesture = await tester.startGesture(last);
        await tester.pump();
        expect(tester.getCenter(pill).dx, closeTo(first.dx, .01));
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          tester.getCenter(pill).dx,
          allOf(greaterThan(first.dx + 1), lessThan(last.dx)),
        );
        expect(calls, isEmpty);
        await tester.pump(const Duration(milliseconds: 104));
        expect(tester.getCenter(pill).dx, closeTo(last.dx, .01));
        expect(calls, isEmpty);
        expect(selected, 0);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, [3]);
        expect(selected, 3);
        expect(tester.getCenter(pill).dx, closeTo(last.dx, .01));
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'short stationary taps commit on up once and interrupt smoothly',
    (tester) async {
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
      final pill = find.byKey(const Key('navigation-glass-indicator'));
      final first = tester.getCenter(find.byKey(const Key('navigation-tab-0')));
      final last = tester.getCenter(find.byKey(const Key('navigation-tab-3')));
      final press = await tester.startGesture(last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final before = tester.getCenter(pill).dx;
      await press.up();
      await tester.pump();
      expect(calls, [3]);
      expect(tester.getCenter(pill).dx, closeTo(before, .01));
      final reverse = await tester.startGesture(first);
      await tester.pump();
      expect(tester.getCenter(pill).dx, closeTo(before, .01));
      expect(calls, [3]);
      await reverse.up();
      await tester.pumpAndSettle();
      expect(calls, [3, 0]);
      expect(tester.getCenter(pill).dx, closeTo(first.dx, .01));
      // Release before any frame, same tab, and successive ordinary taps.
      for (final tab in [2, 2, 1, 0]) {
        final count = calls.length;
        final previous = selected;
        final point = tester.getCenter(find.byKey(Key('navigation-tab-$tab')));
        final gesture = await tester.startGesture(point);
        expect(calls.length, count);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls.length, count + (tab == previous ? 0 : 1));
        expect(selected, tab);
      }
      expect(calls, [3, 0, 2, 1, 0]);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final system in [false, true]) {
    testWidgets('reduced animation responds on down and commits on up $system', (
      tester,
    ) async {
      final calls = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: system),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: GlassNavigation(
                  index: 0,
                  reducedMotion: !system,
                  onChanged: calls.add,
                ),
              ),
            ),
          ),
        ),
      );
      final point = tester.getCenter(find.byKey(const Key('navigation-tab-3')));
      final gesture = await tester.startGesture(point);
      await tester.pump();
      expect(
        tester
            .getCenter(find.byKey(const Key('navigation-glass-indicator')))
            .dx,
        closeTo(point.dx, .01),
      );
      expect(calls, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(calls, [3]);
      // This test's parent rejects the selection, so the preview returns home.
      expect(
        tester
            .getCenter(find.byKey(const Key('navigation-glass-indicator')))
            .dx,
        closeTo(
          tester.getCenter(find.byKey(const Key('navigation-tab-0'))).dx,
          .01,
        ),
      );
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'one pointer owns preview; sub-slop movement retargets immediately',
    (tester) async {
      final calls = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: GlassNavigation(index: 0, onChanged: calls.add),
            ),
          ),
        ),
      );
      final end = tester.getCenter(find.byKey(const Key('navigation-tab-3')));
      final middle = tester.getCenter(
        find.byKey(const Key('navigation-tab-1')),
      );
      final owner = await tester.startGesture(end, pointer: 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final before = tester
          .getCenter(find.byKey(const Key('navigation-glass-indicator')))
          .dx;
      final other = await tester.startGesture(middle, pointer: 2);
      await other.moveBy(const Offset(-20, 0));
      await other.cancel();
      await owner.moveBy(const Offset(-2, 0));
      await tester.pump();
      expect(
        tester
            .getCenter(find.byKey(const Key('navigation-glass-indicator')))
            .dx,
        closeTo(before, .01),
      );
      await tester.pump(const Duration(milliseconds: 104));
      expect(
        tester
            .getCenter(find.byKey(const Key('navigation-glass-indicator')))
            .dx,
        closeTo(end.dx - 2, .01),
      );
      expect(calls, isEmpty);
      await owner.up();
      await tester.pumpAndSettle();
      expect(calls, [3]);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('secondary mouse press does not preview or select', (
    tester,
  ) async {
    final calls = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: GlassNavigation(index: 0, onChanged: calls.add),
          ),
        ),
      ),
    );
    final point = tester.getCenter(find.byKey(const Key('navigation-tab-3')));
    final gesture = await tester.startGesture(
      point,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getCenter(find.byKey(const Key('navigation-glass-indicator'))).dx,
      closeTo(
        tester.getCenter(find.byKey(const Key('navigation-tab-0'))).dx,
        .01,
      ),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  for (final kind in ['pointer', 'background', 'resize', 'modal']) {
    testWidgets('stationary preview cancels on $kind without stale release', (
      tester,
    ) async {
      final calls = <int>[];
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: GlassNavigation(index: 0, onChanged: calls.add),
            ),
          ),
        ),
      );
      final point = tester.getCenter(find.byKey(const Key('navigation-tab-3')));
      final gesture = await tester.startGesture(point);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      if (kind == 'pointer') await gesture.cancel();
      if (kind == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      if (kind == 'resize') {
        tester.view.physicalSize = const Size(900, 600);
        addTearDown(tester.view.resetPhysicalSize);
      }
      if (kind == 'modal') {
        nav.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('modal')),
          ),
        );
      }
      await tester.pumpAndSettle();
      if (kind != 'pointer') await gesture.up();
      if (kind == 'modal') {
        nav.currentState!.pop();
      }
      if (kind == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(
        tester
            .getCenter(find.byKey(const Key('navigation-glass-indicator')))
            .dx,
        closeTo(
          tester.getCenter(find.byKey(const Key('navigation-tab-0'))).dx,
          .01,
        ),
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'semantic and keyboard button actions survive physical gesture ownership',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final calls = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: GlassNavigation(index: 0, onChanged: calls.add),
              ),
            ),
          ),
        );
        final finder = find.byKey(const Key('navigation-tab-3'));
        final press = await tester.startGesture(tester.getCenter(finder));
        await tester.pump();
        final semantic = tester.getSemantics(find.bySemanticsLabel('账户'));
        expect(
          semantic.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
        );
        await press.cancel();
        await tester.pumpAndSettle();
        semantic.owner!.performAction(semantic.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(calls, [3]);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(calls.length, 2);
        await tester.pumpWidget(const SizedBox());
      } finally {
        handle.dispose();
      }
    },
  );
}
