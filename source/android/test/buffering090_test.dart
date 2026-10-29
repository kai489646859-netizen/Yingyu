import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/audio_decode_watch.dart';
import 'package:yingyu/playback/disc_startup.dart';
import 'runtime_health_test.dart' show sample;

void main() {
  for (final mode in ['buffer', 'cache', 'seek', 'pause']) {
    test('$mode does not spend audio recovery playback budget', () {
      final watch = AudioDecodeWatch()..fault(Duration.zero, playing: true);
      watch.sample(sample(1, 1, 1));
      watch.suspend();
      expect(
        watch.sample(
          sample(
            56,
            1,
            1,
            buffering: mode == 'buffer',
            cachePaused: mode == 'cache',
            seeking: mode == 'seek',
            playing: mode != 'pause',
          ),
        ),
        AudioDecodeAction.none,
      );
      expect(watch.pending, true);
      expect(watch.sample(sample(57, 1, 1)), AudioDecodeAction.none);
      expect(watch.sample(sample(58, 2, 2)), AudioDecodeAction.verified);
    });
  }
  test(
    'buffer event between probes clears old running interval and anchor',
    () {
      final watch = AudioDecodeWatch()..fault(Duration.zero, playing: true);
      watch.sample(sample(1, 1, 1));
      watch.suspend();
      expect(watch.sample(sample(56, 2, 2)), AudioDecodeAction.none);
      expect(watch.sample(sample(57, 3, 3)), AudioDecodeAction.verified);
    },
  );
  test('actual eight seconds without audio output still fails', () {
    final watch = AudioDecodeWatch()..fault(Duration.zero, playing: true);
    watch.sample(sample(1, 1, 1));
    expect(watch.sample(sample(8, 8, 1)), AudioDecodeAction.fail);
  });
  test('eight packet errors remain fatal even while buffering', () {
    final watch = AudioDecodeWatch();
    for (var i = 0; i < 8; i++) {
      watch.fault(Duration(seconds: i), playing: false);
    }
    expect(
      watch.sample(sample(55, 0, 0, buffering: true)),
      AudioDecodeAction.fail,
    );
  });
  for (final values in [
    {
      'demuxer-cache-duration': '4',
      'demuxer-cache-idle': 'no',
      'eof-reached': 'no',
    },
    {
      'demuxer-cache-duration': '.2',
      'demuxer-cache-idle': 'yes',
      'eof-reached': 'no',
    },
    {
      'demuxer-cache-duration': '.2',
      'demuxer-cache-idle': 'no',
      'eof-reached': 'yes',
    },
  ]) {
    test('cold cushion accepts real full/EOF/4sec $values', () async {
      final result = await waitForDiscCushion(
        read: (key) async => values[key] ?? '',
        active: () => true,
      );
      expect(result, isNot(contains('等待结束')));
    });
  }
  test(
    'cold cushion waits for actual bytes instead of inventing duration',
    () async {
      var rounds = 0;
      final result = await waitForDiscCushion(
        read: (key) async {
          if (key == 'demuxer-cache-duration') {
            return ++rounds >= 2 ? '4.1' : '.1';
          }
          return 'no';
        },
        active: () => true,
      );
      expect(rounds, 2);
      expect(result, contains('已达到内核恢复门槛'));
    },
  );
  test('unknown properties fall back to native conditions', () async {
    expect(
      await waitForDiscCushion(
        read: (_) => Future.error(StateError('unknown')),
        active: () => true,
      ),
      contains('暂不可确认'),
    );
  });
  test(
    'cold cushion is bounded even when native read never completes',
    () async {
      final watch = Stopwatch()..start();
      await waitForDiscCushion(
        read: (_) => Completer<String>().future,
        active: () => true,
        timeout: const Duration(milliseconds: 30),
      );
      expect(watch.elapsedMilliseconds, lessThan(500));
    },
  );
  test('pause exit or new play intent cancels cold cushion', () async {
    var active = true;
    final result = await waitForDiscCushion(
      read: (_) async {
        active = false;
        return 'no';
      },
      active: () => active,
    );
    expect(result, '已取消');
  });
}
