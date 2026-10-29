import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';

const _mib = 1024 * 1024;
DiscRangeBlock _prefix(int start, int count, {int total = 64 * _mib}) =>
    DiscRangeBlock(
      start,
      total,
      Uint8List(count)..fillRange(0, count, start ~/ _mib + 7),
    );

void main() {
  for (final action in [
    'complete',
    'fail',
    'close',
    'seek',
    'identity',
    'overflow',
  ]) {
    test('partial prefix preserves $action boundary', () async {
      final tail = Completer<DiscRangeBlock>();
      final cancelled = <int>[];
      DiscReadProgress? publish;
      var calls = 0;
      final cache = DiscRangeCache(
        (p, s, n, c) async => throw StateError('legacy fetch not expected'),
        progressiveFetch: (p, s, n, c, progress) async {
          calls++;
          if (s != 0) return _prefix(s, n);
          publish = progress;
          c.abort = () {
            cancelled.add(s);
            if (!tail.isCompleted) {
              tail.completeError(const AppFailure('cancelled tail'));
            }
          };
          progress(_prefix(s, _mib));
          return tail.future;
        },
      );
      try {
        final first = await cache.read('', 0, _mib);
        expect(first.bytes.length, _mib);
        expect(first.bytes.every((v) => v == 7), isTrue);
        expect(
          cache.cachedBytes,
          0,
          reason: 'Incomplete blocks are not committed to reusable cache.',
        );
        if (action == 'seek') {
          await cache.read('', 40 * _mib, _mib);
          expect(cancelled, [0]);
        } else if (action == 'close') {
          cache.close();
          await expectLater(
            cache.read('', _mib, _mib),
            throwsA(isA<AppFailure>()),
          );
          expect(cancelled, [0]);
        } else {
          final second = cache.read('', _mib, _mib);
          if (action == 'complete') {
            // Recovery can replay a shorter prefix without invalidating data
            // already delivered from the same validated source.
            publish!(_prefix(0, _mib ~/ 2));
            publish!(_prefix(0, 2 * _mib));
            expect((await second).bytes.every((v) => v == 7), isTrue);
            tail.complete(_prefix(0, 4 * _mib));
            await Future<void>.delayed(Duration.zero);
            expect(calls, lessThanOrEqualTo(3));
            expect(
              (await cache.read('', 0, _mib)).bytes.every((v) => v == 7),
              isTrue,
            );
          } else {
            if (action == 'identity' || action == 'overflow') {
              expect(
                () => publish!(
                  action == 'identity'
                      ? _prefix(0, 2 * _mib, total: 65 * _mib)
                      : _prefix(0, 5 * _mib),
                ),
                throwsA(isA<AppFailure>()),
              );
            }
            tail.completeError(const AppFailure('tail invalid'));
            await expectLater(second, throwsA(isA<AppFailure>()));
          }
        }
      } finally {
        cache.close();
        if (!tail.isCompleted) {
          tail.completeError(const AppFailure('fixture closed'));
        }
        await Future<void>.delayed(Duration.zero);
      }
    });
  }
}
