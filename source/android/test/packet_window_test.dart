import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'host/replay076/packet_window.dart';

void main() {
  testWidgets(
    'production window ends after 45 seconds and restores prefix map',
    (tester) async {
      final n = NativePlayer()..option = 'all=error';
      final h = PacketWindowHarness(n);
      await h.start();
      expect(h.active, true);
      expect(n.levels.last, 'terminal-default');
      await tester.pump(const Duration(seconds: 45));
      await h.stop();
      expect(h.active, false);
      expect(n.option, 'all=error');
      expect(n.levels.last, 'warn');
      await h.close();
    },
  );
  test(
    'ordinary media and disabled diagnostics never change native options',
    () async {
      final n = NativePlayer();
      final h = PacketWindowHarness(n)..ordinary();
      await h.start();
      expect(n.writes, isEmpty);
      final disabled = PacketWindowHarness(n);
      disabled.log!.enabled = false;
      await disabled.start();
      expect(n.writes, isEmpty);
    },
  );
  test(
    'unsupported native request restores original options and closes window',
    () async {
      final n = NativePlayer()..result = -1;
      final h = PacketWindowHarness(n);
      await h.start();
      expect(h.active, false);
      expect(n.option, 'all=warn');
      expect(h.log!.rows.last, contains('未启用'));
      await h.close();
    },
  );
  test(
    'closing during native read cannot leave a trace window running',
    () async {
      final gate = Completer<String>();
      final n = NativePlayer()..readGate = gate;
      final h = PacketWindowHarness(n);
      final started = h.start();
      await Future<void>.delayed(Duration.zero);
      await h.close();
      gate.complete('all=error');
      await started;
      expect(h.active, false);
      expect(n.option, 'all=error');
      expect(n.levels, isNot(contains('terminal-default')));
    },
  );
}
