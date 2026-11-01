import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/log_storage.dart';
import 'package:yingyu/playback/player_status.dart';

class SlowStorage206 extends LogFileStorage {
  SlowStorage206() : super(File('unused-synthetic-journal'));
  final gate = Completer<void>();
  final entered = Completer<void>();
  final saved = <String>[];
  int calls = 0;
  @override
  Future<void> append(
    List<String> rows,
    List<String> Function() snapshot,
  ) async {
    if (++calls == 1) {
      entered.complete();
      await gate.future;
    }
    saved.addAll(rows);
  }

  @override
  Future<void> replace(List<String> rows) async {
    saved
      ..clear()
      ..addAll(rows);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'slow journal coalesces repeated flush work and preserves every row',
    () async {
      final disk = SlowStorage206();
      final log = DiagnosticLog(storage: disk);
      log.add(LogArea.player, 'first');
      final first = log.flush();
      await disk.entered.future;
      final waiting = <Future<void>>{};
      for (var i = 0; i < 10000; i++) {
        if (i % 100 == 0) log.add(LogArea.player, 'row$i');
        waiting.add(log.flush());
      }
      final queued = waiting.length;
      disk.gate.complete();
      await Future.wait([first, ...waiting]);
      expect(disk.saved.length, 101);
      expect(disk.saved.toSet().length, 101);
      expect(disk.calls, 2);
      log.dispose();
      expect(
        queued,
        1,
        reason:
            'pending flush calls must share one drain, not retain 10000 closures',
      );
    },
  );
  testWidgets(
    'four hours of stalled native status retain one request and recover',
    (tester) async {
      final pending = <Completer<Map<Object?, Object?>?>>[];
      final c = PlayerStatusController(
        read: () {
          final p = Completer<Map<Object?, Object?>?>();
          pending.add(p);
          return p.future;
        },
      );
      c.setActive(true);
      await tester.pump();
      for (var i = 0; i < 14400; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      c.value = PlayerStatusData(time: DateTime(1970));
      await tester.pump(const Duration(seconds: 1));
      expect(c.value.time.year, isNot(1970));
      final outstanding = pending.length;
      c.setActive(false);
      for (final p in pending) {
        p.complete({'batteryPercent': 99});
      }
      await tester.pump();
      expect(
        c.value.batteryPercent,
        isNull,
        reason: 'late timeout data must not become fresh',
      );
      pending.clear();
      c.setActive(true);
      await tester.pump();
      expect(pending.length, 1);
      pending.single.complete({'batteryPercent': 42});
      await tester.pump();
      expect(c.value.batteryPercent, 42);
      c.dispose();
      await tester.pump();
      expect(outstanding, 1, reason: 'timeout does not cancel platform work');
    },
  );
}
