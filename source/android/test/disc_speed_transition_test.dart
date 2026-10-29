import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';

void main() {
  const mib = 1024 * 1024;
  test(
    'increasing speed primes the full bounded forward window immediately',
    () async {
      final starts = <int>[];
      final cache = DiscRangeCache((path, start, length, cancel) async {
        starts.add(start);
        return DiscRangeBlock(start, 128 * mib, Uint8List(length));
      });
      addTearDown(cache.close);
      await cache.read('', 0, mib);
      await cache.read('', mib, mib);
      await Future<void>.delayed(Duration.zero);
      expect(starts, [0, 4 * mib]);
      cache.setSpeed(3);
      await Future<void>.delayed(Duration.zero);
      expect(starts, [for (var i = 0; i < 8; i++) i * 4 * mib]);
      expect(cache.cachedBytes, lessThanOrEqualTo(32 * mib));
    },
  );

  test(
    'releasing held speed preserves an in-flight continuous response',
    () async {
      var opens = 0, closes = 0;
      final stalled = Completer<void>(), release = Completer<void>();
      final reader = DiscStreamReader((path, start, cancellation) async {
        opens++;
        return DiscStreamSource(
          start: start,
          total: 32 * mib,
          bytes: () async* {
            for (var at = start; at < 32 * mib; at += mib) {
              if (at == 8 * mib && !stalled.isCompleted) {
                stalled.complete();
                await release.future;
              }
              yield Uint8List(mib)..fillRange(0, mib, at ~/ mib);
            }
          }(),
          close: (_) => closes++,
        );
      });
      final cache = DiscRangeCache(reader.read)..setSpeed(3);
      try {
        await cache.read('', 0, mib);
        await cache.read('', mib, mib);
        await stalled.future;
        cache.setSpeed(1);
        await cache.read('', 2 * mib, mib);
        expect(
          closes,
          0,
          reason: 'shrinking the window must not cancel the active stream',
        );
        release.complete();
        for (var at = 3 * mib; at < 32 * mib; at += mib) {
          final bytes = (await cache.read('', at, mib)).bytes;
          expect(bytes.first, at ~/ mib);
          expect(bytes.last, at ~/ mib);
        }
        expect(opens, 1);
      } finally {
        if (!release.isCompleted) release.complete();
        cache.close();
        await reader.close();
      }
    },
  );
}
