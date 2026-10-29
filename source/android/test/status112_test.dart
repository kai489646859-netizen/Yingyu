import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/player_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('showing controls replaces a pending rate-only read immediately', (
    tester,
  ) async {
    var full = 0;
    final rate = Completer<Map<Object?, Object?>?>();
    final status = PlayerStatusController(
      read: () async {
        full++;
        return {'network': 'wifi', 'rxBytesPerSecond': 2048.0};
      },
      readRate: () => rate.future,
    );
    status.setKeepRateWarm(true);
    status.setActive(true);
    rate.complete({'rxBytesPerSecond': 0.0});
    await tester.pump();
    expect(full, 1);
    expect(status.value.network, 'wifi');
    expect(status.value.rxBytesPerSecond, 2048);
    status.dispose();
  });
  testWidgets(
    'status refreshes once a second without half-second zero flashes',
    (tester) async {
      var full = 0, warm = 0, updates = 0;
      final status = PlayerStatusController(
        read: () async {
          full++;
          return {'network': 'wifi', 'rxBytesPerSecond': 1500.0};
        },
        readRate: () async {
          warm++;
          return {'rxBytesPerSecond': 0.0};
        },
      )..addListener(() => updates++);
      status.setActive(true);
      await tester.pump();
      expect(full, 1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(warm, 0);
      expect(updates, 1);
      expect(status.value.rxBytesPerSecond, 1500);
      await tester.pump(const Duration(milliseconds: 500));
      expect(full, 2);
      expect(updates, 2);
      status.setKeepRateWarm(true);
      await tester.pump();
      status.setActive(false);
      await tester.pump();
      final hiddenFull = full, hiddenUpdates = updates, hiddenWarm = warm;
      await tester.pump(const Duration(seconds: 1));
      expect(full, hiddenFull);
      expect(updates, hiddenUpdates);
      expect(warm, hiddenWarm + 1);
      status.setKeepRateWarm(false);
      await tester.pump();
      final stopped = warm;
      await tester.pump(const Duration(seconds: 3));
      expect(warm, stopped);
      status.dispose();
    },
  );
  testWidgets('late status result cannot overwrite a newer visibility epoch', (
    tester,
  ) async {
    final gate = Completer<Map<Object?, Object?>?>();
    final status = PlayerStatusController(read: () => gate.future);
    status.setActive(true);
    status.setActive(false);
    gate.complete({'network': 'cellular', 'rxBytesPerSecond': 99999.0});
    await tester.pump();
    expect(status.value.rxBytesPerSecond, isNull);
    expect(status.value.network, 'unknown');
    status.dispose();
  });
}
