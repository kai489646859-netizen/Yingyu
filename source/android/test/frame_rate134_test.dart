import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/frame_rate_hint.dart';

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'one actual FPS read and one hint for 1000 unchanged playback samples; exact speed retained',
    () async {
      final rows = <Map<String, Object>>[];
      final hints = PlaybackFrameRateHints(
        send: (value) async {
          rows.add(value);
          return {'status': 'requested'};
        },
      );
      final owner = Object();
      var reads = 0;
      for (var i = 0; i < 1000; i++) {
        hints.update(
          owner: owner,
          speed: 3,
          active: true,
          readFps: () async {
            reads++;
            return 25;
          },
        );
      }
      await settle();
      expect(reads, 1);
      expect(rows.length, 1);
      expect(rows.single['fps'], 25);
      expect(rows.single['speed'], 3);
      hints.update(
        owner: owner,
        speed: 2,
        active: true,
        readFps: () async {
          reads++;
          return 25;
        },
      );
      await settle();
      expect(rows.last['speed'], 2);
      expect(reads, 1);
      hints.update(
        owner: owner,
        speed: 1,
        active: true,
        readFps: () async {
          reads++;
          return 25;
        },
      );
      await settle();
      expect(rows.last['active'], false);
      final count = rows.length;
      for (var i = 0; i < 1000; i++) {
        hints.update(
          owner: owner,
          speed: 1,
          active: true,
          readFps: () async => 25,
        );
      }
      await settle();
      expect(rows.length, count);
      await hints.close();
      expect(rows.last['retire'], true);
    },
  );
  test(
    'late old source read cannot apply to next episode; old release cannot replace new owner',
    () async {
      final rows = <Map<String, Object>>[];
      final hints = PlaybackFrameRateHints(
        send: (value) async {
          rows.add(value);
          return null;
        },
      );
      final old = Completer<double?>();
      hints.update(
        owner: Object(),
        speed: 3,
        active: true,
        readFps: () => old.future,
      );
      hints.update(
        owner: Object(),
        speed: 2,
        active: true,
        readFps: () async => 24,
      );
      await settle();
      old.complete(60);
      await settle();
      final positive = rows.where((r) => r['active'] == true).toList();
      expect(positive.length, 1);
      expect(positive.single['fps'], 24);
      expect(
        (rows.first['owner'] as int),
        lessThan(positive.single['owner'] as int),
      );
      await hints.close();
    },
  );
  for (final invalid in [null, 0.0, double.nan, double.infinity, 1001.0]) {
    test(
      'unknown/invalid FPS $invalid never requests a display mode',
      () async {
        final rows = <Map<String, Object>>[];
        final hints = PlaybackFrameRateHints(
          send: (v) async {
            rows.add(v);
            return null;
          },
        );
        hints.update(
          owner: Object(),
          speed: 3,
          active: true,
          readFps: () async => invalid,
        );
        await settle();
        expect(rows.where((r) => r['active'] == true), isEmpty);
        await hints.close();
      },
    );
  }
  test(
    'pause during FPS read and closing before queued hint prevent positive apply',
    () async {
      final rows = <Map<String, Object>>[];
      final fps = Completer<double?>();
      final owner = Object();
      final hints = PlaybackFrameRateHints(
        send: (v) async {
          rows.add(v);
          return null;
        },
      );
      hints.update(
        owner: owner,
        speed: 3,
        active: true,
        readFps: () => fps.future,
      );
      hints.update(
        owner: owner,
        speed: 3,
        active: false,
        readFps: () => fps.future,
      );
      fps.complete(25);
      await settle();
      expect(rows.where((r) => r['active'] == true), isEmpty);
      hints.update(
        owner: owner,
        speed: 3,
        active: true,
        readFps: () async => 25,
      );
      await hints.close();
      expect(rows.where((r) => r['active'] == true), isEmpty);
    },
  );
}
