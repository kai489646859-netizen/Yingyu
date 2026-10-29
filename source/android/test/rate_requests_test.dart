import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/rate_requests.dart';
import 'package:yingyu/playback/observation.dart';

void main() {
  testWidgets('raise, release and menu changes never wait for a timer', (
    tester,
  ) async {
    var speed = 1.0;
    final writes = <double>[];
    final requests = RateRequests(
      current: () => speed,
      apply: (value, _) async {
        writes.add(value);
        speed = value;
      },
      changed: () {},
      record: (_) {},
    );
    await requests.request(3, SpeedChangeSource.holdStart);
    await requests.request(1, SpeedChangeSource.holdEnd);
    expect(speed, 1);
    expect(writes, [3, 1]);
    await requests.request(2, SpeedChangeSource.menu);
    expect(writes, [3, 1, 2]);
    await tester.pump(const Duration(seconds: 4));
    expect(writes, [3, 1, 2]);
    await requests.close();
  });

  test('same actual rate creates no native call on hold or release', () async {
    for (final speed in [2.0, 3.0]) {
      final writes = <double>[];
      final requests = RateRequests(
        current: () => speed,
        apply: (value, _) async => writes.add(value),
        changed: () {},
        record: (_) {},
      );
      await requests.request(speed, SpeedChangeSource.holdStart);
      await requests.request(speed, SpeedChangeSource.holdEnd);
      expect(writes, isEmpty);
      await requests.close();
    }
  });

  test(
    'an executing raise and early release remain serial and restore the base',
    () async {
      var speed = 1.0;
      final writes = <double>[];
      final gate = Completer<void>();
      final requests = RateRequests(
        current: () => speed,
        apply: (value, _) async {
          writes.add(value);
          if (value == 3) await gate.future;
          speed = value;
        },
        changed: () {},
        record: (_) {},
      );
      final raise = requests.request(3, SpeedChangeSource.holdStart);
      final release = requests.request(1, SpeedChangeSource.holdEnd);
      expect(writes, [3]);
      gate.complete();
      await Future.wait([raise, release]);
      expect(writes, [3, 1]);
      expect(speed, 1);
      await requests.close();
    },
  );

  test(
    'only an unstarted request behind an active command can be replaced',
    () async {
      var speed = 1.0;
      final writes = <double>[];
      final gate = Completer<void>();
      final requests = RateRequests(
        current: () => speed,
        apply: (value, _) async {
          writes.add(value);
          await gate.future;
          speed = value;
        },
        changed: () {},
        record: (_) {},
      );
      final raise = requests.request(3, SpeedChangeSource.holdStart);
      final restore = requests.request(1, SpeedChangeSource.holdEnd);
      final menu = requests.request(2, SpeedChangeSource.menu);
      await restore;
      expect(writes, [3]);
      gate.complete();
      await Future.wait([raise, menu, requests.flush()]);
      expect(writes, [3, 2]);
      await requests.close();
    },
  );

  test(
    'closing retires an unstarted request and waits for the active call',
    () async {
      var speed = 1.0;
      final writes = <double>[];
      final gate = Completer<void>();
      final requests = RateRequests(
        current: () => speed,
        apply: (value, _) async {
          writes.add(value);
          await gate.future;
          speed = value;
        },
        changed: () {},
        record: (_) {},
      );
      final raise = requests.request(3, SpeedChangeSource.holdStart);
      final restore = requests.request(1, SpeedChangeSource.holdEnd);
      final closing = requests.close();
      await restore;
      gate.complete();
      await Future.wait([raise, closing]);
      expect(writes, [3]);
    },
  );

  test(
    'a failed immediate decrease stays visible and the next choice works',
    () async {
      var speed = 3.0;
      final requests = RateRequests(
        current: () => speed,
        apply: (value, _) async {
          if (value == 1) throw StateError('synthetic native rejection');
          speed = value;
        },
        changed: () {},
        record: (_) {},
      );
      await expectLater(
        requests.request(1, SpeedChangeSource.menu),
        throwsStateError,
      );
      expect(speed, 3);
      await requests.request(2, SpeedChangeSource.menu);
      expect(speed, 2);
      await requests.close();
    },
  );
}
