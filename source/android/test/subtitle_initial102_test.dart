import 'package:flutter_test/flutter_test.dart';
import 'host/subtitle102/initial_position.dart';

void main() {
  test(
    'real pre-load preference block restores bitmap position without opening, seeking or changing HDR/track options',
    () async {
      final h = InitialPositionHarness();
      h.configureSubtitlePosition(35);
      expect(h.automatic, false);
      expect(h.alignment.x, 0);
      expect(h.alignment.y, closeTo(.3, 1e-9));
      await h.apply();
      expect(h.io.values['sub-pos'], '65.000');
      expect(h.io.values['sid'], 'no');
      expect(h.io.values['sub-delay'], '1.5');
      expect(h.io.values['target-trc'], 'pq');
      expect(h.io.writes, ['sub-pos']);
    },
  );
  test(
    'no remembered preference adds no native write or read requirement',
    () async {
      final h = InitialPositionHarness()..io.reject = true;
      h.configureSubtitlePosition(null);
      await h.apply();
      expect(h.automatic, true);
      expect(h.io.writes, isEmpty);
    },
  );
  test(
    'preference rejection falls back to automatic, without failing playback',
    () async {
      final h = InitialPositionHarness()..io.reject = true;
      h.configureSubtitlePosition(50);
      await h.apply();
      expect(h.automatic, true);
      expect(h.io.values['yingyu-subtitle-below-picture'], 'yes');
    },
  );
  test('failed optional fallback does not fail media opening', () async {
    final h = InitialPositionHarness()
      ..io.reject = true
      ..io.rejectReset = true;
    h.configureSubtitlePosition(50);
    await h.apply();
    expect(h.automatic, true);
  });
  test('retired load cannot restore preference into the next load', () async {
    final h = InitialPositionHarness();
    h.configureSubtitlePosition(50);
    h.io.afterWrite = h.retire;
    await expectLater(h.apply(), throwsException);
    expect(h.io.writes, ['sub-pos']);
  });
  test(
    'configuration after load or disposal cannot replace active placement',
    () {
      for (final advance in <void Function(InitialPositionHarness)>[
        (h) => h.retire(),
        (h) => h.opening(),
        (h) => h.dispose(),
      ]) {
        final h = InitialPositionHarness();
        h.configureSubtitlePosition(40);
        advance(h);
        h.configureSubtitlePosition(80);
        expect(h.alignment.x, 0);
        expect(h.alignment.y, closeTo(.2, 1e-9));
      }
    },
  );
}
