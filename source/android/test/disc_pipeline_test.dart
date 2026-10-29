import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';

const mib = 1024 * 1024;
DiscRangeBlock bytesAt(int start) =>
    DiscRangeBlock(start, 64 * mib, Uint8List(4 * mib));

void main() {
  for (final speed in [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
    test(
      'pipeline at ${speed}x fills the idle HTTP slot while a demanded block is waiting',
      () async {
        final pending = <int, Completer<DiscRangeBlock>>{};
        final cache = DiscRangeCache((path, start, length, cancellation) async {
          if (start == 0) return bytesAt(start);
          final gate = pending[start] = Completer<DiscRangeBlock>();
          cancellation.abort = () {
            if (!gate.isCompleted) {
              gate.completeError(const AppFailure('synthetic cancellation'));
            }
          };
          return gate.future;
        });
        addTearDown(cache.close);
        cache.setSpeed(speed);
        for (var start = 0; start < 4 * mib; start += mib) {
          await cache.read('clip', start, mib);
        }
        expect(pending.containsKey(4 * mib), true);
        final demand = cache.read('clip', 4 * mib, mib);
        unawaited(demand.then<void>((_) {}, onError: (Object _) {}));
        try {
          // The current block remains deliberately blocked. The next HTTP range
          // must already have started, rather than waiting for that block to end.
          expect(
            pending.containsKey(8 * mib),
            true,
            reason:
                'the next range must start before the current awaited range completes',
          );
          expect(cache.activeRequests, 2);
          pending[4 * mib]!.complete(bytesAt(4 * mib));
          expect((await demand).bytes.length, mib);
        } finally {
          cache.close();
          try {
            await demand;
          } on AppFailure {
            /* cancellation cleanup */
          }
        }
      },
    );
  }
  test('waiting on the final block never speculates past EOF', () async {
    final requested = <int>[];
    final gate = Completer<DiscRangeBlock>();
    final cache = DiscRangeCache((path, start, length, cancel) async {
      requested.add(start);
      if (start == 0) {
        return DiscRangeBlock(0, 4 * mib + 71, Uint8List(4 * mib));
      }
      return gate.future;
    });
    addTearDown(cache.close);
    for (var start = 0; start < 4 * mib; start += mib) {
      await cache.read('clip', start, mib);
    }
    final tail = cache.read('clip', 4 * mib, mib);
    expect(requested, [0, 4 * mib]);
    gate.complete(DiscRangeBlock(4 * mib, 4 * mib + 71, Uint8List(71)));
    expect((await tail).bytes.length, 71);
    expect(requested, [0, 4 * mib]);
  });
}
