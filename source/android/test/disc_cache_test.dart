import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_buffering.dart';

const mib = 1024 * 1024;
DiscRangeBlock block(int start, {int total = 64 * mib}) => DiscRangeBlock(
  start,
  total,
  Uint8List((total - start).clamp(0, 4 * mib))
    ..fillRange(0, (total - start).clamp(0, 4 * mib), start ~/ mib),
);

void main() {
  test(
    'slow native speed changes preserve press/release order and recover after an error',
    () async {
      final gate = Completer<void>();
      final applied = <double>[];
      final queue = PlaybackRateQueue((rate) async {
        if (rate == 3) await gate.future;
        if (rate == .5) {
          throw const AppFailure('synthetic native option failure');
        }
        applied.add(rate);
      });
      await queue.set(1.5);
      final held = queue.set(3);
      final released = queue.set(1.5);
      await Future<void>.delayed(Duration.zero);
      expect(applied, [1.5]);
      gate.complete();
      await Future.wait([held, released]);
      expect(applied, [1.5, 3.0, 1.5]);
      await expectLater(queue.set(.5), throwsA(isA<AppFailure>()));
      await queue.set(1);
      expect(applied.last, 1);
    },
  );
  test(
    '33 one-MiB demands coalesce into nine blocks, preserve 64-bit offsets and reuse backseeks',
    () async {
      final requests = <int>[];
      const base = 5 * 1024 * mib;
      final cache = DiscRangeCache((path, start, length, cancel) async {
        requests.add(start);
        expect(length, 4 * mib);
        return block(start, total: base + 33 * mib);
      });
      addTearDown(cache.close);
      for (var i = 0; i < 33; i++) {
        final bytes = await cache.read('', base + i * mib, mib);
        expect(bytes.bytes.length, mib);
        expect(bytes.bytes.first, ((base + (i ~/ 4) * 4 * mib) ~/ mib) % 256);
      }
      await cache.read('', base + 8 * mib, mib);
      expect(requests.length, 9);
      expect(requests.toSet().length, 9);
      expect(cache.cachedBytes, lessThanOrEqualTo(32 * mib));
    },
  );

  test(
    'overlapping demands share one fetch and cross-block bytes remain ordered',
    () async {
      final gate = Completer<void>();
      var count = 0;
      final cache = DiscRangeCache((path, start, length, cancel) async {
        count++;
        await gate.future;
        return block(start);
      });
      addTearDown(cache.close);
      final a = cache.read('clip', 3 * mib + mib ~/ 2, mib);
      final b = cache.read('clip', 3 * mib, 123);
      expect(count, 1);
      gate.complete();
      final bytes = (await a).bytes;
      expect(bytes.take(mib ~/ 2).every((v) => v == 0), true);
      expect(bytes.skip(mib ~/ 2).every((v) => v == 4), true);
      expect((await b).bytes.every((v) => v == 0), true);
      expect(count, 2);
    },
  );

  test(
    'all speed presets keep bounded prefetch and the selected MPV cushion',
    () async {
      for (final speed in [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
        final cache = DiscRangeCache(
          (p, s, n, c) async => block(s),
          maxBytes: 16 * mib,
        );
        cache.setSpeed(speed);
        expect(cache.aheadBlocks, speed.ceil().clamp(1, 3));
        final options = discBufferOptions(speed);
        expect(
          double.parse(options['cache-pause-wait']!) / speed,
          speed > 2 ? 8 : 2,
        );
        expect(options['cache-pause-initial'], 'yes');
        expect(
          double.parse(options['cache-secs']!),
          speed > 2 ? 180 : 20 * speed,
        );
        for (var at = 0; at < 40 * mib; at += mib) {
          await cache.read('clip', at, mib);
          expect(cache.cachedBytes, lessThanOrEqualTo(16 * mib));
          expect(cache.activeRequests, lessThanOrEqualTo(2));
        }
        cache.close();
      }
    },
  );

  test(
    'seek cancels obsolete speculative I/O and prioritizes new demand, maximum two active requests',
    () async {
      final cancelled = <int>[];
      final pending = <int, Completer<DiscRangeBlock>>{};
      var active = 0, peak = 0;
      final cache = DiscRangeCache((path, start, length, cancel) async {
        active++;
        if (active > peak) peak = active;
        try {
          if (start == 0 || start >= 40 * mib) return block(start);
          final gate = pending[start] = Completer<DiscRangeBlock>();
          cancel.abort = () {
            cancelled.add(start);
            gate.completeError(const AppFailure('synthetic cancellation'));
          };
          return await gate.future;
        } finally {
          active--;
        }
      });
      cache.setSpeed(3);
      addTearDown(cache.close);
      await cache.read('a', 0, mib);
      await cache.read('a', mib, mib);
      expect(pending.keys.toSet(), {4 * mib, 8 * mib});
      final sought = await cache.read('a', 40 * mib, mib);
      expect(sought.start, 40 * mib);
      expect(cancelled.toSet(), {4 * mib, 8 * mib});
      expect(peak, lessThanOrEqualTo(2));
      expect(
        pending.containsKey(12 * mib),
        false,
        reason: 'queued speculation must be discarded',
      );
    },
  );

  test(
    'speculation errors do not poison playback; demand retries and EOF is exact',
    () async {
      var attempts = 0;
      final cache = DiscRangeCache((path, start, length, cancel) async {
        if (start == 4 * mib && ++attempts == 1) {
          throw const AppFailure('synthetic prefetch failure');
        }
        return block(start, total: 4 * mib + 71);
      });
      addTearDown(cache.close);
      await cache.read('a', 0, mib);
      await cache.read('a', mib, mib);
      await Future<void>.delayed(Duration.zero);
      final tail = await cache.read('a', 4 * mib, mib);
      expect(tail.bytes.length, 71);
      expect(tail.total, 4 * mib + 71);
      expect(attempts, 2);
    },
  );

  test(
    'incomplete blocks are rejected and close cancels demanded reads',
    () async {
      final cache = DiscRangeCache(
        (p, s, n, c) async => DiscRangeBlock(s, 64 * mib, Uint8List(1)),
      );
      await expectLater(cache.read('', 0, 16), throwsA(isA<AppFailure>()));
      expect(cache.cachedBytes, 0);
      cache.close();
      final gate = Completer<DiscRangeBlock>();
      final blocked = DiscRangeCache((p, s, n, c) async {
        c.abort = () => gate.completeError(const AppFailure('closed'));
        return gate.future;
      });
      final read = blocked.read('', 0, 16);
      final error = expectLater(read, throwsA(isA<AppFailure>()));
      blocked.close();
      await error;
      expect(blocked.cachedBytes, 0);
    },
  );

  test(
    'stall deadline ignores pause, EOF, movement and seeking, reports only once',
    () {
      final watch = DiscBufferWatch();
      bool sample(
        int time,
        int position, {
        bool play = true,
        bool buffer = true,
        bool end = false,
      }) => watch.sample(
        now: Duration(seconds: time),
        position: Duration(seconds: position),
        playing: play,
        buffering: buffer,
        completed: end,
      );
      expect(sample(0, 1), false);
      expect(sample(55, 2), false);
      expect(sample(100, 2, play: false), false);
      expect(sample(200, 2), false);
      expect(sample(259, 2), false);
      expect(sample(260, 2), true);
      expect(sample(270, 2), false);
      watch.reset();
      expect(sample(400, 2), false);
      expect(sample(460, 2, end: true), false);
      expect(sample(600, 2, buffer: false), false);
    },
  );
}
