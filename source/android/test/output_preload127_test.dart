import 'package:flutter_test/flutter_test.dart';
import 'host/output127/current.dart' as current;
import 'host/output127/old.dart' as old;

void main() {
  test(
    'ordinary media prepares the parsed Surface without enabling Dolby mapping',
    () async {
      final h = current.HookHarness();
      h.native.values['yingyu-preloaded-dolby-vision-profile'] = '0';
      await h.preload();
      expect(h.failure, isNull);
      expect(h.video.mapped, false);
      expect(h.video.prepares, 1);
      expect(h.video.prepared, true);
    },
  );
  test(
    'decoder continuation has a sized Surface instead of waiting for decoded videoParams',
    () async {
      final h = current.HookHarness();
      await h.preload();
      expect(h.failure, isNull);
      expect(h.video.mapped, true);
      expect(
        h.video.prepared,
        true,
        reason:
            'Before decoder continuation, parsed dimensions must prepare the Surface needed by direct MediaCodec',
      );
      expect(h.video.prepares, 1);
    },
  );
  test('complete126 continues decoding with no prepared Surface', () async {
    final h = old.HookHarness();
    await h.preload();
    expect(h.failure, isNull);
    expect(h.video.mapped, true);
    expect(h.video.prepared, false);
    expect(h.video.prepares, 0);
  });
}
