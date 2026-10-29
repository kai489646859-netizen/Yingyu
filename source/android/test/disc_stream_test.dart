import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';

void main() {
  const mib = 1024 * 1024;
  for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]) {
    test(
      '$speed x consumes bounded blocks from one backpressured stream',
      () async {
        var opens = 0, produced = 0, closes = 0;
        final reader = DiscStreamReader((path, start, cancellation) async {
          opens++;
          expect(start, 0);
          return DiscStreamSource(
            start: start,
            total: 128 * mib,
            bytes: () async* {
              for (var offset = start; offset < 128 * mib; offset += mib) {
                produced++;
                yield Uint8List(mib)..fillRange(0, mib, offset ~/ mib);
              }
            }(),
            close: (_) => closes++,
          );
        });
        final cache = DiscRangeCache(reader.read, maxBytes: 16 * mib)
          ..setSpeed(speed);
        try {
          for (var offset = 0; offset < 64 * mib; offset += mib) {
            final block = await cache.read('', offset, mib);
            expect(block.bytes.first, offset ~/ mib);
            expect(block.bytes.last, offset ~/ mib);
            expect(cache.cachedBytes, lessThanOrEqualTo(16 * mib));
          }
          await Future<void>.delayed(Duration.zero);
          // At most the ahead window plus one paused iterator chunk, not the
          // remaining film. No consumer means no further stream pulls.
          expect(produced, lessThanOrEqualTo(64 + speed.ceil() * 4 + 1));
          final stoppedAt = produced;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(produced, stoppedAt);
          expect(opens, 1);
          expect(reader.reusedBlocks, greaterThanOrEqualTo(15));
        } finally {
          cache.close();
          await reader.close();
        }
        expect(closes, 1);
      },
    );
  }

  test(
    'a discontinuous seek closes the old response before opening the new one',
    () async {
      final events = <String>[];
      final reader = DiscStreamReader((path, start, cancellation) async {
        events.add('open:$start');
        return DiscStreamSource(
          start: start,
          total: 1024,
          bytes: Stream.value(Uint8List(1024 - start)),
          close: (_) => events.add('close:$start'),
        );
      });
      await reader.read('', 0, 16, DiscReadCancellation());
      await reader.read('', 16, 16, DiscReadCancellation());
      await reader.read('', 900, 16, DiscReadCancellation());
      await reader.close();
      expect(events, ['open:0', 'close:0', 'open:900', 'close:900']);
    },
  );

  test(
    'a truncated body is terminal and does not reopen on repeated reads',
    () async {
      var opens = 0;
      final reader = DiscStreamReader((path, start, cancellation) async {
        opens++;
        return DiscStreamSource(
          start: start,
          total: 1024,
          bytes: Stream.value([1, 2]),
          close: (_) {},
        );
      });
      for (var i = 0; i < 3; i++) {
        await expectLater(
          reader.read('', 0, 16, DiscReadCancellation()),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(opens, 1);
      await reader.close();
    },
  );

  test('cancelled queued reads never open another media response', () async {
    var opens = 0;
    final bytes = StreamController<List<int>>();
    final ready = Completer<void>();
    final reader = DiscStreamReader((path, start, cancellation) async {
      opens++;
      ready.complete();
      return DiscStreamSource(
        start: start,
        total: 1024,
        bytes: bytes.stream,
        close: (_) {},
      );
    });
    final firstCancel = DiscReadCancellation(),
        queuedCancel = DiscReadCancellation();
    final first = reader.read('', 0, 16, firstCancel);
    final firstFailed = expectLater(first, throwsA(isA<AppFailure>()));
    final queued = reader.read('', 512, 16, queuedCancel);
    final queuedFailed = expectLater(queued, throwsA(isA<AppFailure>()));
    await ready.future;
    await Future<void>.delayed(Duration.zero);
    queuedCancel.cancel();
    firstCancel.cancel();
    await Future.wait([firstFailed, queuedFailed]);
    expect(opens, 1);
    await reader.close();
    await bytes.close();
  });
}
