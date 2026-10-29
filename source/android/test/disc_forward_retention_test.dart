import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';

void main() {
  for (final capacity in [16, 32]) {
    test(
      '3x full $capacity MiB read-ahead never evicts the next block or reopens HTTP',
      () async {
        const unit = 1024 * 1024, total = 96 * unit;
        final starts = <int>[];
        final stream = DiscStreamReader((path, start, cancellation) async {
          starts.add(start);
          return DiscStreamSource(
            start: start,
            total: total,
            close: (_) {},
            bytes: () async* {
              for (
                var at = start;
                at < total;
                at += DiscRangeCache.blockBytes
              ) {
                yield Uint8List(DiscRangeCache.blockBytes)..fillRange(
                  0,
                  DiscRangeCache.blockBytes,
                  at ~/ DiscRangeCache.blockBytes,
                );
              }
            }(),
          );
        });
        final cache = DiscRangeCache(stream.read, maxBytes: capacity * unit)
          ..setSpeed(3);
        try {
          for (var at = 0; at < total; at += unit) {
            final block = await cache.read('', at, unit);
            expect(block.bytes.first, at ~/ DiscRangeCache.blockBytes);
            expect(block.bytes.last, at ~/ DiscRangeCache.blockBytes);
            // Fill the bounded window before consuming more, as a fast network
            // does while the native decoder is processing the current block.
            for (var i = 0; i < 8; i++) {
              await Future<void>.delayed(Duration.zero);
            }
            expect(cache.cachedBytes, lessThanOrEqualTo(capacity * unit));
          }
          expect(
            starts,
            [0],
            reason: 'sequential playback must not reread evicted future bytes',
          );
        } finally {
          cache.close();
          await stream.close();
        }
      },
    );
  }
}
