import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/orientation.dart';
import 'package:yingyu/ui/poster_press.dart';
import 'package:yingyu/ui/settings_choice.dart';

void main() {
  testWidgets(
    'poster press darkens, releases, cancels on scroll and preserves parent taps',
    (tester) async {
      var taps = 0;
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scroll,
              children: [
                GestureDetector(
                  onTap: () => taps++,
                  child: const SizedBox(
                    height: 200,
                    child: PosterPressFeedback(
                      child: ColoredBox(color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      );
      final position = tester.getCenter(find.byType(PosterPressFeedback));
      final touch = await tester.startGesture(position);
      await tester.pump();
      expect(find.byKey(const Key('poster-pressed')), findsOneWidget);
      await touch.up();
      await tester.pump();
      expect(find.byKey(const Key('poster-pressed')), findsNothing);
      expect(taps, 1);
      final drag = await tester.startGesture(position);
      await tester.pump();
      await drag.moveBy(const Offset(0, -70));
      await tester.pump();
      expect(find.byKey(const Key('poster-pressed')), findsNothing);
      await drag.moveBy(const Offset(0, -80));
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      await drag.up();
      expect(taps, 1);
      scroll.jumpTo(0);
      await tester.pump();
      final cancel = await tester.startGesture(position);
      await tester.pump();
      await cancel.cancel();
      await tester.pump();
      expect(find.byKey(const Key('poster-pressed')), findsNothing);
      final departing = await tester.startGesture(position);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await departing.up();
      await tester.pump();
      expect(tester.takeException(), isNull);
      scroll.dispose();
    },
  );
  testWidgets('poster press resets when its page becomes inactive', (
    tester,
  ) async {
    Widget scene(bool active) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: 120,
          height: 180,
          child: PosterPressFeedback(
            active: active,
            child: const ColoredBox(color: Colors.white),
          ),
        ),
      ),
    );
    await tester.pumpWidget(scene(true));
    final touch = await tester.startGesture(
      tester.getCenter(find.byType(PosterPressFeedback)),
    );
    await tester.pump();
    expect(find.byKey(const Key('poster-pressed')), findsOneWidget);
    await tester.pumpWidget(scene(false));
    expect(find.byKey(const Key('poster-pressed')), findsNothing);
    await touch.up();
  });
  for (final width in [360.0, 800.0, 1280.0]) {
    testWidgets(
      'settings arrow anchor survives scroll and closes on rotation width=$width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final scroll = ScrollController();
        var chosen = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                controller: scroll,
                children: [
                  const SizedBox(height: 220),
                  SettingsChoice<int>(
                    id: 'choice',
                    title: '设置标题',
                    subtitle: '说明文字',
                    value: 0,
                    choices: const {0: '选项一', 1: '选项二'},
                    onChanged: (value) => chosen = value,
                  ),
                  const SizedBox(height: 1200),
                ],
              ),
            ),
          ),
        );
        for (final text in ['设置标题', '说明文字']) {
          await tester.tap(find.text(text));
          await tester.pumpAndSettle();
          expect(find.text('选项一'), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
        }
        final arrow = find.byKey(const ValueKey('choice-arrow'));
        void expectArrow(bool expanded) {
          final rotation = find.descendant(
            of: arrow,
            matching: find.byType(RotationTransition),
          );
          expect(rotation, findsOneWidget);
          expect(
            (rotation.evaluate().single.widget as RotationTransition)
                .turns
                .value,
            closeTo(expanded ? .25 : 0, .0001),
          );
        }

        expectArrow(false);
        await tester.tap(arrow);
        await tester.pumpAndSettle();
        expectArrow(true);
        expect(
          tester.getRect(find.text('选项一')).right,
          lessThan(tester.getRect(arrow).right),
        );
        final item = find.byKey(const ValueKey('choice-choice-0'));
        expect(
          tester.getRect(item).right,
          closeTo(tester.getRect(arrow).right, 1),
        );
        scroll.jumpTo(100);
        await tester.pumpAndSettle();
        expect(find.text('选项一'), findsNothing);
        expectArrow(false);
        await tester.tap(arrow);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(item).right,
          closeTo(tester.getRect(arrow).right, 1),
        );
        await tester.tap(find.text('选项二'));
        await tester.pumpAndSettle();
        expect(chosen, 1);
        expectArrow(false);
        await tester.tap(arrow);
        await tester.pumpAndSettle();
        tester.view.physicalSize = Size(800, width);
        await tester.pumpAndSettle();
        expect(find.text('选项一'), findsNothing);
        expectArrow(false);
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
      },
    );
  }
  testWidgets(
    'player orientation leases remain independent and release only once',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlaybackOrientation.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          PlaybackOrientation.channel,
          null,
        ),
      );
      final first = PlaybackOrientation(), next = PlaybackOrientation();
      await first.enter();
      await next.enter();
      await first.release();
      await first.release();
      await next.release();
      expect(calls.length, 4);
      expect(calls.map((call) => call.arguments['active']), [
        true,
        true,
        false,
        false,
      ]);
      expect(calls[0].arguments['owner'], calls[2].arguments['owner']);
      expect(calls[1].arguments['owner'], calls[3].arguments['owner']);
      expect(calls[0].arguments['owner'], isNot(calls[1].arguments['owner']));
    },
  );
}
