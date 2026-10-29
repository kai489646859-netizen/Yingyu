import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'host/playback107/placement.dart';

void main() {
  test(
    'resetting disc subtitles restores authored MPV positioning rather than external below-picture layout',
    () async {
      final h = PlacementHarness()..disc();
      await expectLater(
        h.resetSubtitlePosition(allowed: () => true),
        throwsA(isA<SubtitlePositionPending>()),
      );
      expect(h.io.values['yingyu-subtitle-screen-position'], 'no');
      expect(h.io.values['yingyu-subtitle-below-picture'], 'no');
      expect(h.io.values['stretch-image-subs-to-screen'], 'no');
      expect(double.parse(h.io.values['sub-pos']!), 100);
      expect(h.io.values['sid'], 'no');
    },
  );
}
