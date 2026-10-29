import 'package:flutter_test/flutter_test.dart';
import 'host/sync162/old/backend.dart' as previous;
import 'host/sync162/new/backend.dart' as current;

void main() {
  const old = bool.fromEnvironment('YINGYU_SYNC162_OLD');
  dynamic create({double speed = 3}) {
    final dynamic b = old
        ? previous.BackendHarness()
        : current.BackendHarness();
    b.start(disc: false, speed: speed);
    b.checkpoint(177.52);
    return b;
  }

  test(
    'accelerated video stall preserves hardware instead of forcing 4K software',
    () async {
      final b = create();
      await b.repair('mediacodec-copy');
      b.positionEvent(177.52);
      expect(b.native.writes, [('hwdec', 'mediacodec-copy')]);
      expect(b.player.seeks, [const Duration(milliseconds: 177520)]);
      expect(b.player.rates, isEmpty);
      expect(b.attempted, isTrue);
    },
  );
  test(
    '157 post-recovery clock trace cannot falsely report sync recovery',
    () async {
      final b = create();
      // This deliberately follows the old software fallback outcome, even if
      // the new policy expected hardware: neither path may confirm this drift.
      await b.repair('mediacodec-copy');
      b.positionEvent(177.52);
      await b.probeAt(6000, 179.64, 181.160719, hardware: 'no');
      await b.probeAt(8000, 182.8, 187.152706, hardware: 'no');
      expect(b.logs.any((String s) => s.contains('视频恢复核对通过')), isFalse);
      expect(b.recovering, isTrue);
      await b.probeAt(38000, 210.32, 241.151122, hardware: 'no');
      expect(b.failure, isNotNull);
    },
  );
  for (final rate in [1.0, 2.0, 3.0]) {
    test(
      'rate $rate repair confirms only continuous synchronized hardware',
      () async {
        final b = create(speed: rate);
        await b.repair('mediacodec-copy');
        b.positionEvent(177.52);
        for (var n = 1; n <= 4; n++) {
          final p = 177.52 + n * 2 * rate;
          await b.probeAt(n * 2000, p, p);
        }
        expect(b.recovering, isFalse);
        expect(b.failure, isNull);
        expect(b.native.writes, [('hwdec', 'mediacodec-copy')]);
        expect(b.player.rates, isEmpty);
      },
    );
  }
  test('advancing but diverging hardware also cannot pass recovery', () async {
    final b = create();
    await b.repair('mediacodec-copy');
    b.positionEvent(177.52);
    for (var n = 1; n <= 17; n++) {
      await b.probeAt(n * 2000, 177.52 + n * 3.2, 177.52 + n * 6);
    }
    expect(b.logs.any((String s) => s.contains('视频恢复核对通过')), isFalse);
    expect(b.failure, isNotNull);
    expect(b.native.writes.length, 1);
  });
}
