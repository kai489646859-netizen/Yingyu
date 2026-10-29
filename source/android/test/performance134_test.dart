import 'package:flutter_test/flutter_test.dart';
import 'host/performance134/current.dart' as current;
import 'host/performance134/old.dart' as old;
import 'opening_surface127_test.dart' show header;

void main() {
  test(
    'ordinary media with unavailable dimensions keeps decoder fallback',
    () async {
      final h = current.Harness();
      h.native.values.addAll(header());
      h.native.values['track-list/0/demux-w'] = '';
      await h.run();
      expect(h.video.preparations, 0);
      expect(h.mapped, false);
    },
  );
  test(
    'cancelled whole ordinary preload never prepares an old Surface',
    () async {
      final h = current.Harness();
      h.native.values.addAll(header());
      h.cancel();
      await h.run();
      expect(h.video.preparations, 0);
    },
  );
  for (final profile in ['', '5', '7']) {
    test(
      'whole preload prepares one surface before decoding profile=$profile',
      () async {
        const baseline = bool.fromEnvironment('YINGYU_COMPARE_OLD');
        final dynamic h = baseline ? old.Harness() : current.Harness();
        h.native.values.addAll(header());
        h.native.values['yingyu-preloaded-dolby-vision-profile'] = profile;
        h.native.values['options/hwdec'] = 'auto-safe';
        await h.run();
        expect(h.video.preparations, 1);
        expect(h.video.sizes.single, [3840, 2160]);
        expect(h.mapped, profile.isNotEmpty);
      },
    );
  }
}
