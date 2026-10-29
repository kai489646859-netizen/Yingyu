import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/observation.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

void main() {
  test(
    'read one native JSON snapshot, never unsupported slash properties',
    () async {
      final requests = <String>[];
      final result = await readPlaybackCache((key) async {
        requests.add(key);
        if (key != 'demuxer-cache-state') return '';
        return '{"fw-bytes":0,"raw-input-rate":262144,"reader-pts":1846.9,'
            '"cache-end":1847.9,"unrelated":"https://secret.invalid/token"}';
      });
      expect(requests, ['demuxer-cache-state']);
      expect(result, {
        'demuxer-cache-state/fw-bytes': '0',
        'demuxer-cache-state/raw-input-rate': '262144',
        'demuxer-cache-state/reader-pts': '1846.9',
        'demuxer-cache-state/cache-end': '1847.9',
      });
    },
  );
  for (final raw in [
    'invalid',
    '[]',
    '{"fw-bytes":"secret"}',
    '{"fw-bytes":-1}',
    ' ' * 65537,
  ]) {
    test(
      'unusable native cache snapshot remains unknown (${raw.length} chars)',
      () async {
        expect(await readPlaybackCache((_) async => raw), isEmpty);
      },
    );
  }
  test(
    'slow native cache read is bounded and late result cannot replace unknown',
    () {
      fakeAsync((clock) {
        final reply = Completer<String>();
        Map<String, String>? result;
        readPlaybackCache((_) => reply.future).then((value) => result = value);
        clock.elapse(const Duration(milliseconds: 300));
        clock.flushMicrotasks();
        expect(result, isEmpty);
        reply.complete('{"fw-bytes":99}');
        clock.flushMicrotasks();
        expect(result, isEmpty);
      });
    },
  );
  test(
    'seek observations distinguish missing from zero and reject old samples',
    () {
      final sample = PlaybackObservation();
      final old = sample.generation;
      sample.record(
        sampleGeneration: old,
        now: Duration.zero,
        speed: 1,
        values: {
          'demuxer-cache-state/fw-bytes': '0',
          'demuxer-cache-state/raw-input-rate': '262144',
          'demuxer-cache-state/reader-pts': '1846.9',
          'demuxer-cache-state/cache-end': '1847.9',
          'stream-path': 'https://secret.invalid/token',
        },
      );
      final text = sample.describe(Duration.zero);
      expect(text, contains('前向包缓存=0.0 字节'));
      expect(text, contains('内核输入速率=262144.0 字节/秒'));
      expect(text, contains('非实测带宽'));
      expect(text, contains('读取起点=1846.9 秒'));
      expect(text, contains('缓存末端=1847.9 秒'));
      expect(text, isNot(contains('secret')));
      sample.invalidate();
      expect(
        sample.record(
          sampleGeneration: old,
          now: Duration.zero,
          speed: 1,
          values: {},
        ),
        false,
      );
      sample.record(
        sampleGeneration: sample.generation,
        now: Duration.zero,
        speed: 1,
        values: {},
      );
      expect(sample.describe(Duration.zero), contains('前向包缓存=未提供'));
      expect(sample.describe(Duration.zero), contains('内核输入速率=未提供'));
    },
  );
  for (final invalid in [
    'NaN',
    'Infinity',
    '-1',
    'https://secret.invalid/token',
  ]) {
    test('invalid transport estimate remains unknown: $invalid', () {
      final sample = PlaybackObservation();
      sample.record(
        sampleGeneration: sample.generation,
        now: Duration.zero,
        speed: 1,
        values: {
          'demuxer-cache-state/fw-bytes': invalid,
          'demuxer-cache-state/raw-input-rate': invalid,
        },
      );
      final text = sample.describe(Duration.zero);
      expect(text, contains('前向包缓存=未提供'));
      expect(text, contains('内核输入速率=未提供'));
      expect(text, isNot(contains('secret')));
    });
  }
}
