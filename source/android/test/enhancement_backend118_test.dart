import 'package:flutter_test/flutter_test.dart';
import 'host/enhancement118/backend.dart';

void main() {
  for (final profile in ['5', '7']) {
    test(
      'complete Dolby backend applies both gains and keeps property IO asynchronous for $profile',
      () async {
        final h = EnhancementBackend()..profile(profile);
        expect(await h.setShadowEnhancement(.75, allowed: () => true), .75);
        expect(await h.setPictureBrightness(15, allowed: () => true), 15);
        expect(h.shadowEnhancement, .75);
        expect(h.generated, contains('//!DESC Yingyu Dolby enhancement v1'));
        expect(h.io.sync, isEmpty);
        expect(h.io.writes.toSet(), {'glsl-shaders'});
        expect(h.log.messages, hasLength(2));
        expect(await h.setPictureBrightness(0, allowed: () => true), 0);
        expect(h.shadowEnhancement, .75);
        await h.setShadowEnhancement(0, allowed: () => true);
        expect(h.io.values['glsl-shaders'], '');
      },
    );
  }
  test(
    'ordinary HDR backend keeps the original shader and property-write path',
    () async {
      final h = EnhancementBackend()..profile('0');
      h.io.render = false;
      expect(await h.setPictureBrightness(15, allowed: () => true), 15);
      expect(h.generated, isNot(contains('Yingyu Dolby enhancement')));
      expect(h.generated, contains('Yingyu colour-preserving enhancement v3'));
      expect(h.io.sync, ['glsl-shaders']);
      expect(h.io.writes.toSet(), {'glsl-shaders'});
    },
  );
}
