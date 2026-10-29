import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/feedback.dart';

void main() {
  for (final spec in [
    (size: const Size(412, 915), ratio: 16 / 9),
    (size: const Size(1280, 800), ratio: 16 / 9),
    (size: const Size(900, 1280), ratio: 2.39),
    (size: const Size(1280, 800), ratio: 9 / 16),
  ]) {
    testWidgets(
      'held speed feedback stays at the user-marked upper center $spec',
      (tester) async {
        tester.view.physicalSize = spec.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaybackFeedback(
                text: '3 倍速',
                boosted: true,
                fit: BoxFit.contain,
                aspectRatio: spec.ratio,
              ),
            ),
          ),
        );
        final box = tester.getRect(
          find.byKey(const Key('playback-gesture-feedback')),
        );
        expect(box.center.dx, closeTo(spec.size.width / 2, 1));
        expect(box.center.dy, closeTo(spec.size.height * .10, 2));
        expect((Offset.zero & spec.size).contains(box.topLeft), true);
        expect((Offset.zero & spec.size).contains(box.bottomRight), true);
        expect(tester.takeException(), null);
      },
    );
  }
  testWidgets(
    'volume and brightness retain the original alignment; filled video feedback stays safe',
    (tester) async {
      for (final text in ['音量 50%', '亮度 50%', '00:42']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: PlaybackFeedback(
                text: text,
                boosted: false,
                fit: BoxFit.contain,
                aspectRatio: 16 / 9,
              ),
            ),
          ),
        );
        final align = tester.widget<Align>(
          find
              .ancestor(
                of: find.byKey(const Key('playback-gesture-feedback')),
                matching: find.byType(Align),
              )
              .first,
        );
        expect(align.alignment, const Alignment(0, -.5));
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                viewPadding: EdgeInsets.only(top: 28, left: 20),
              ),
              child: const PlaybackFeedback(
                text: '3 倍速',
                boosted: true,
                fit: BoxFit.cover,
                aspectRatio: 16 / 9,
              ),
            ),
          ),
        ),
      );
      final box = tester.getRect(
        find.byKey(const Key('playback-gesture-feedback')),
      );
      expect(box.top, greaterThanOrEqualTo(28));
      expect(box.left, greaterThanOrEqualTo(20));
    },
  );
}
