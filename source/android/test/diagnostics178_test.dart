import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/playback/diagnostic_budget.dart';
import 'package:yingyu/playback/display_diagnostics.dart';
import 'package:yingyu/playback/resource_diagnostics.dart';
import 'package:yingyu/playback/session.dart';
import 'playback_test.dart' show FakeBackend;

class ClosingBackend extends FakeBackend
    implements PlaybackDiagnosticLifecycle {
  bool stopped = false;
  final pausing = Completer<void>();
  @override
  void stopDiagnostics() {
    stopped = true;
  }

  @override
  Future<void> pause() => pausing.future;
}

class StalledLog extends DiagnosticLog {
  final gate = Completer<void>();
  int flushes = 0;
  @override
  Future<void> flush() {
    flushes++;
    return gate.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'exit stops collection synchronously before a blocked pause or progress report',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = EmbyClient();
      final backend = ClosingBackend();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'synthetic', 'Type': 'Movie'}),
        backend: backend,
      );
      final closing = session.close();
      final stoppedBeforeAwait = backend.stopped;
      backend.pausing.complete();
      await closing;
      expect(stoppedBeforeAwait, isTrue);
      expect(backend.disposed, isTrue);
      session.dispose();
      api.close();
      store.dispose();
    },
  );
  test('a stalled final journal write cannot block leaving playback', () async {
    SharedPreferences.setMockInitialValues({});
    final log = StalledLog()..enabled = false;
    final store = AppStore(await SharedPreferences.getInstance(), log: log);
    final api = EmbyClient();
    final backend = FakeBackend();
    final session = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'synthetic'}),
      backend: backend,
    );
    try {
      await session.close().timeout(const Duration(milliseconds: 200));
      expect(log.flushes, greaterThan(0));
      expect(backend.disposed, isTrue);
    } finally {
      log.gate.complete();
      session.dispose();
      api.close();
      store.dispose();
      log.dispose();
    }
  });
  test(
    'two-hour stream stays bounded, abnormalities retain 2s evidence, exit and pause reject events',
    () {
      final b = DiagnosticBudget();
      var normal = 0;
      for (var i = 0; i < 7200; i++) {
        if (b.allow('video', Duration(seconds: i))) normal++;
      }
      expect(normal, 720);
      expect(
        b.allow('video', const Duration(seconds: 7192), abnormal: true),
        true,
      );
      expect(
        b.allow('video', const Duration(seconds: 7193), abnormal: true),
        false,
      );
      expect(b.allow('other', Duration.zero, playing: false), false);
      expect(b.allow('other', Duration.zero, enabled: false), false);
      b.stop();
      for (var i = 7200; i < 10800; i++) {
        expect(b.allow('video', Duration(seconds: i), abnormal: true), false);
      }
      b.reset();
      expect(b.allow('video', Duration.zero), true);
    },
  );
  test(
    'changing native counters retain a fixed category and stage names remain distinct',
    () {
      final b = DiagnosticBudget();
      var count = 0;
      for (var i = 0; i < 10000; i++) {
        final family = DiagnosticBudget.nativeFamily(
          'Yingyu timing162 video=$i audio=$i',
        );
        if (b.allow(family, Duration(milliseconds: i))) count++;
      }
      expect(count, 1);
      expect(
        DiagnosticBudget.nativeFamily('Yingyu stage136 name=decode calls=3'),
        isNot(
          DiagnosticBudget.nativeFamily('Yingyu stage136 name=upload calls=3'),
        ),
      );
    },
  );
  test(
    'late color reads after exit are discarded and raw strings never exported',
    () async {
      var active = true;
      final gate = Completer<String>();
      final job = colorDiagnostics((_) => gate.future, active: () => active);
      active = false;
      gate.complete('pq');
      expect(await job, isNull);
      final row = await colorDiagnostics(
        (_) async => 'https://secret.invalid',
        active: () => true,
      );
      expect(row, isNot(contains('secret')));
      expect(row, contains('colorlevels=未提供'));
    },
  );
  test(
    'resource CPU deltas reject resets and missing values, never claim watts or PSS',
    () {
      final r = ResourceObservation();
      expect(r.describe({'cpuMs': 100, 'elapsedMs': 1000}), contains('区间=未提供'));
      expect(
        r.describe({'cpuMs': 3100, 'elapsedMs': 2000}),
        contains('300.0%'),
      );
      expect(r.describe({'cpuMs': 10, 'elapsedMs': 3000}), contains('区间=未提供'));
      r.reset();
      expect(r.describe({}), contains('thermal=未提供'));
    },
  );
  testWidgets(
    'records are visible immediately and a final flush persists without another tick',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final log = DiagnosticLog(prefs: prefs);
      log.add(LogArea.player, 'synthetic event');
      expect(log.entries.length, 1);
      await tester.runAsync(log.flush);
      expect(prefs.getStringList(DiagnosticLog.entriesKey)!.length, 1);
      log.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(log.entries.length, 1);
    },
  );
}
