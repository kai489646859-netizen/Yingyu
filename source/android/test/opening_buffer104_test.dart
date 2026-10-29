import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/opening_buffer.dart';

void main() {
  test(
    'delayed cache invalidation after initial sid reply cannot pass on the old seven seconds',
    () async {
      var elapsed = Duration.zero;
      final result = await settleOpeningBuffer(
        elapsed: () => elapsed,
        wait: (d) async => elapsed += d,
        active: () => true,
        read: (key) async {
          final cold =
              elapsed >= const Duration(milliseconds: 300) &&
              elapsed < const Duration(seconds: 4);
          return {
            'seeking': cold ? 'yes' : 'no',
            'paused-for-cache': cold ? 'yes' : 'no',
            'demuxer-cache-duration': cold ? '0' : '7.032000',
            'demuxer-cache-idle': 'no',
            'eof-reached': 'no',
            'cache-pause-wait': '4',
          }[key]!;
        },
      );
      expect(result, contains('衔接完成'));
      expect(elapsed, const Duration(milliseconds: 4500));
    },
  );
  for (final duration in ['0', '-1', 'NaN', 'Infinity', '9000']) {
    test(
      'invalid or insufficient cache $duration stays bounded and does not become ready',
      () async {
        var elapsed = Duration.zero;
        final result = await settleOpeningBuffer(
          elapsed: () => elapsed,
          wait: (d) async => elapsed += d,
          active: () => true,
          read: (key) async =>
              key == 'demuxer-cache-duration' ? duration : 'no',
        );
        expect(result, contains('有界等待结束'));
        expect(elapsed, const Duration(seconds: 5));
      },
    );
  }
  for (final stop in ['demuxer-cache-idle', 'eof-reached']) {
    test('real $stop does not require a fabricated duration', () async {
      var elapsed = Duration.zero;
      final result = await settleOpeningBuffer(
        elapsed: () => elapsed,
        wait: (d) async => elapsed += d,
        active: () => true,
        read: (key) async => key == stop
            ? 'yes'
            : key == 'demuxer-cache-duration'
            ? ''
            : 'no',
      );
      expect(result, contains('衔接完成'));
      expect(elapsed, const Duration(milliseconds: 500));
    });
  }
  test('close, pause or superseding intent cancels the old wait', () async {
    var elapsed = Duration.zero, active = true;
    final result = await settleOpeningBuffer(
      elapsed: () => elapsed,
      wait: (d) async {
        elapsed += d;
        active = false;
      },
      active: () => active,
      read: (key) async => key == 'demuxer-cache-duration' ? '0' : 'no',
    );
    expect(result, '已取消');
    expect(elapsed, const Duration(milliseconds: 50));
  });
  test(
    'an unavailable property keeps genuine native buffering and failures',
    () async {
      final result = await settleOpeningBuffer(
        active: () => true,
        read: (_) async => throw StateError('not available'),
      );
      expect(result, contains('未知'));
    },
  );
}
