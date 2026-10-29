import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_buffer_phase.dart';
import 'package:yingyu/playback/disc_cache_retention.dart';

void main() {
  const mib = 1024 * 1024;
  DiscBufferPlan plan(double speed, {bool fast = false, int memory = 128}) =>
      DiscBufferPlan(
        speed: speed,
        fast: fast,
        baseBytes: 128 * mib,
        memoryMiB: memory,
      );

  testWidgets(
    '3x prefetch steps down after 2s and 4s with a 1x resume gate throughout',
    (tester) async {
      var cache = plan(3).withPlaybackSpeed(1);
      final tiers = <double>[];
      final valid = <bool>[];
      late final DiscCacheRetention retention;
      retention = DiscCacheRetention((generation, tier) {
        valid.add(retention.isCurrent(generation));
        cache = plan(tier).withPlaybackSpeed(1);
        tiers.add(tier);
        retention.afterRate(cache, 1);
      });
      retention.afterRate(cache, 1);
      expect(cache.tier, 3);
      expect(cache.bytes, 768 * mib);
      expect(cache.options['cache-pause-wait'], '2.00');
      expect(cache.options['cache-secs'], '180.00');
      await tester.pump(const Duration(milliseconds: 1999));
      expect(tiers, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tiers, [2]);
      expect(cache.bytes, 384 * mib);
      expect(cache.options['cache-pause-wait'], '2.00');
      await tester.pump(const Duration(milliseconds: 1999));
      expect(tiers, [2]);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tiers, [2, 1]);
      expect(cache.bytes, 128 * mib);
      expect(valid, [true, true]);
      await tester.pump(const Duration(seconds: 8));
      expect(tiers, [2, 1]);
      retention.cancel();
    },
  );

  for (final speed in [1.25, 1.5, 2.0]) {
    testWidgets('restored $speed only drops to its 2x cache tier', (
      tester,
    ) async {
      final tiers = <double>[];
      final gates = <String?>[];
      late final DiscCacheRetention retention;
      retention = DiscCacheRetention((_, tier) {
        tiers.add(tier);
        final next = plan(tier).withPlaybackSpeed(speed);
        gates.add(next.options['cache-pause-wait']);
        retention.afterRate(next, speed);
      });
      retention.afterRate(plan(3).withPlaybackSpeed(speed), speed);
      await tester.pump(const Duration(seconds: 2));
      expect(tiers, [2]);
      expect(gates, ['4.00']);
      await tester.pump(const Duration(seconds: 4));
      expect(tiers, [2]);
      retention.cancel();
    });
  }

  testWidgets(
    're-holding 3x cancels the old expiry and a new release restarts its two seconds',
    (tester) async {
      final tiers = <double>[];
      final retention = DiscCacheRetention((_, tier) => tiers.add(tier));
      retention.afterRate(plan(3).withPlaybackSpeed(1), 1);
      await tester.pump(const Duration(milliseconds: 1500));
      retention.afterRate(plan(3), 3);
      await tester.pump(const Duration(seconds: 3));
      expect(tiers, isEmpty);
      retention.afterRate(plan(3).withPlaybackSpeed(1), 1);
      await tester.pump(const Duration(milliseconds: 1999));
      expect(tiers, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tiers, [2]);
      retention.cancel();
    },
  );

  testWidgets(
    'a newer speed, seek or close invalidates even an already queued expiry',
    (tester) async {
      int? expiry;
      final retention = DiscCacheRetention(
        (generation, _) => expiry = generation,
      );
      retention.afterRate(plan(3).withPlaybackSpeed(1), 1);
      await tester.pump(const Duration(seconds: 2));
      expect(expiry, isNotNull);
      retention.cancel();
      expect(retention.isCurrent(expiry!), isFalse);
      retention.afterRate(plan(3).withPlaybackSpeed(2), 2);
      retention.cancel();
      final before = expiry;
      await tester.pump(const Duration(seconds: 5));
      expect(expiry, before);
    },
  );

  testWidgets(
    'fast opening and seeking keep their 1x budget without retained tiers',
    (tester) async {
      final tiers = <double>[];
      final retention = DiscCacheRetention((_, tier) => tiers.add(tier));
      final quick = plan(3, fast: true).withPlaybackSpeed(3);
      retention.afterRate(quick, 3);
      expect(quick.tier, 1);
      expect(quick.bytes, 128 * mib);
      expect(quick.options['cache-pause-wait'], '2.00');
      await tester.pump(const Duration(seconds: 5));
      expect(tiers, isEmpty);
      retention.cancel();
    },
  );

  test('retaining a low-memory plan cannot grow its existing allocation', () {
    final retained = plan(3, memory: 32).withPlaybackSpeed(1);
    expect(retained.tier, 3);
    expect(retained.bytes, 128 * mib);
    expect(retained.options['cache-pause-wait'], '2.00');
  });
}
