import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'host/playback107/placement.dart';

void main() {
  test(
    'complete backend methods: default, manual endpoints and reset preserve disabled subtitles',
    () async {
      final h = PlacementHarness();
      expect(h.usesDefaultSubtitlePosition, true);
      expect(await h.setSubtitlePosition(100, allowed: () => true), 100);
      expect(h.usesDefaultSubtitlePosition, false);
      expect(h.configuration.alignment, Alignment.topCenter);
      expect(h.io.values['yingyu-subtitle-below-picture'], 'no');
      expect(h.io.values['sub-pos'], '0.000');
      expect(await h.setSubtitlePosition(0, allowed: () => true), 0);
      expect(h.usesDefaultSubtitlePosition, false);
      expect(h.configuration.alignment, Alignment.bottomCenter);
      expect(await h.readSubtitlePosition(allowed: () => true), 0);
      await expectLater(
        h.resetSubtitlePosition(allowed: () => true),
        throwsA(isA<SubtitlePositionPending>()),
      );
      expect(h.usesDefaultSubtitlePosition, true);
      expect(h.io.values['yingyu-subtitle-below-picture'], 'yes');
      expect(h.io.values['sid'], 'no');
      expect(h.emits, 3);
      expect(h.io.writes.toSet(), {'sub-pos', 'yingyu-subtitle-below-picture'});
    },
  );
  test(
    'the complete backend keeps text mode unchanged after a retired native write',
    () async {
      final h = PlacementHarness();
      h.io.afterWrite = h.retire;
      await expectLater(
        h.setSubtitlePosition(100, allowed: () => true),
        throwsException,
      );
      expect(h.usesDefaultSubtitlePosition, true);
      expect(h.configuration.alignment, Alignment.bottomCenter);
      expect(h.emits, 0);
      expect(h.io.writes, ['yingyu-subtitle-below-picture']);
    },
  );
  test('a disabled session cannot write subtitle placement', () async {
    final h = PlacementHarness();
    await expectLater(
      h.setSubtitlePosition(50, allowed: () => false),
      throwsException,
    );
    await expectLater(
      h.resetSubtitlePosition(allowed: () => false),
      throwsException,
    );
    expect(h.io.writes, isEmpty);
    expect(h.emits, 0);
  });
  test(
    'default reading uses the displayed text or bitmap position, then manual remains exact',
    () async {
      final h = PlacementHarness();
      h.io.values['yingyu-subtitle-position'] = '85';
      expect(await h.readSubtitlePosition(allowed: () => true), 15);
      h.textPosition(12.5);
      expect(await h.readSubtitlePosition(allowed: () => true), 12.5);
      await h.setSubtitlePosition(17.5, allowed: () => true);
      expect(await h.readSubtitlePosition(allowed: () => true), 17.5);
    },
  );
}
