import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/audio_ducking.dart';

void main() {
  test(
    'duck preserves internal baseline, idempotence and system-independent pause intent',
    () async {
      double volume = 75;
      final writes = <double>[];
      final duck = PlaybackDucking(
        read: () => volume,
        write: (v) async {
          writes.add(v);
          volume = v;
        },
      );
      await duck.set(true);
      await duck.set(true);
      expect(volume, 15);
      await duck.set(false);
      await duck.set(false);
      expect(volume, 75);
      expect(writes, [15, 75]);
    },
  );
  test('rapid duck gain duck serialize actual gain changes', () async {
    double volume = 100;
    final gate = Completer<void>();
    var calls = 0;
    final duck = PlaybackDucking(
      read: () => volume,
      write: (v) async {
        if (calls++ == 0) await gate.future;
        volume = v;
      },
    );
    final a = duck.set(true), b = duck.set(false), c = duck.set(true);
    gate.complete();
    await Future.wait([a, b, c]);
    expect(volume, 20);
    await duck.set(false);
    expect(volume, 100);
  });
  test(
    'a failed write surfaces and later focus changes remain usable',
    () async {
      double volume = 60;
      bool fail = true;
      final duck = PlaybackDucking(
        read: () => volume,
        write: (v) async {
          if (fail) {
            fail = false;
            throw StateError('synthetic');
          }
          volume = v;
        },
      );
      await expectLater(duck.set(true), throwsStateError);
      await duck.set(true);
      expect(volume, 12);
      await duck.set(false);
      expect(volume, 60);
    },
  );
  test('disposed player receives no queued or later commands', () async {
    var writes = 0;
    final duck = PlaybackDucking(
      read: () => 100,
      write: (_) async {
        writes++;
      },
    );
    final job = duck.set(true);
    await duck.close();
    await job;
    await duck.set(false);
    expect(writes, 0);
  });
}
