import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_stream.dart';

void main() {
  test(
    'receive observations count data and retain failed opening time separately',
    () async {
      final metrics = DiscReadMetrics();
      final stream = StreamController<List<int>>();
      final iterator = StreamIterator(stream.stream);
      final next = metrics.next(iterator);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(metrics.health, contains('正文等待累计='));
      expect(metrics.receivedBytes, 0);
      stream.add([1, 2, 3, 4]);
      expect(await next, isTrue);
      expect(metrics.receivedBytes, 4);
      expect(metrics.bodyMicroseconds, greaterThanOrEqualTo(10000));
      await expectLater(
        metrics.opening(() async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          throw StateError('synthetic header failure');
        }),
        throwsStateError,
      );
      expect(metrics.openMicroseconds, greaterThanOrEqualTo(10000));
      expect(metrics.receivedBytes, 4);
      await iterator.cancel();
      await stream.close();
    },
  );

  test(
    'two overlapping receive waits count each body once and finish on close',
    () async {
      final metrics = DiscReadMetrics();
      final first = StreamController<List<int>>(),
          second = StreamController<List<int>>();
      final a = StreamIterator(first.stream), b = StreamIterator(second.stream);
      final one = metrics.next(a), two = metrics.next(b);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      first.add([1, 2]);
      second.add([3, 4, 5]);
      expect(await Future.wait([one, two]), [true, true]);
      expect(metrics.receivedBytes, 5);
      expect(metrics.bodyMicroseconds, greaterThanOrEqualTo(20000));
      final eof = metrics.next(a);
      await first.close();
      expect(await eof, isFalse);
      expect(metrics.receivedBytes, 5);
      await a.cancel();
      await b.cancel();
      await second.close();
    },
  );
}
