import 'dart:isolate';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'host/stability206/new/worker.dart' as current;
import 'host/stability206/old/worker.dart' as old;
import 'host/power201/new/worker.dart' as worker_main;

const baseline = bool.fromEnvironment('STABILITY206_OLD');
Future<void> turn() => Future<void>.delayed(const Duration(milliseconds: 10));
void main() {
  if (!baseline) {
    test(
      'worker command loop applies logging preference without suppressing failure or control',
      () async {
        final worker = worker_main.WorkerHarness()..initialLogging = false;
        await worker.start();
        expect(worker.logging, false);
        worker.command(['logging', true]);
        expect(worker.logging, true);
        worker.command(['logging', false]);
        expect(worker.logging, false);
        worker.command(['speed', 2.0]);
        expect(worker.transport.rates.last, 2.0);
        worker.transport.onFailure('synthetic failure');
        expect(worker.events.any((dynamic e) => e[0] == 'failed'), true);
        worker.command(['close']);
        await turn();
        expect(worker.transport.closes, 1);
      },
    );
  }
  test('disabled worker emits no log messages under sustained load', () async {
    final events = ReceivePort(), messages = <dynamic>[];
    events.listen(messages.add);
    final log = (baseline ? old.workerLog206 : current.workerLog206)(
      events.sendPort,
      false,
    );
    for (var i = 0; i < 10000; i++) {
      log.add(LogArea.player, 'sample$i');
    }
    await turn();
    final disabled = messages.length;
    messages.clear();
    log.enabled = true;
    log.add(LogArea.player, 'visible');
    await turn();
    expect(messages.length, 1);
    log.dispose();
    events.close();
    expect(disabled, 0);
  });
  test(
    'worker logging follows user switches once and detaches on close',
    () async {
      final events = ReceivePort(), messages = <dynamic>[];
      events.listen(messages.add);
      final log = DiagnosticLog();
      await log.setEnabled(false);
      final route = PlaybackRoute(
        url: 'http://synthetic.invalid/a.iso',
        headers: {},
        sourceId: 'a',
        sessionId: 'b',
        streams: [],
      );
      final worker = (baseline
          ? old.connectedWorker206
          : current.connectedWorker206)(route, log, events.sendPort);
      await turn();
      final first = messages
          .where((dynamic e) => e[0] == 'logging')
          .map((dynamic e) => e[1])
          .toList();
      messages.clear();
      await log.setEnabled(true);
      for (var i = 0; i < 1000; i++) {
        log.add(LogArea.player, 'line$i');
      }
      await turn();
      final toggles = messages
          .where((dynamic e) => e[0] == 'logging')
          .map((dynamic e) => e[1])
          .toList();
      messages.clear();
      await worker.close();
      await log.setEnabled(false);
      await turn();
      final after = messages.length;
      await log.flush();
      log.dispose();
      events.close();
      expect(first, [false]);
      expect(toggles, [true]);
      expect(after, 0);
    },
  );
}
