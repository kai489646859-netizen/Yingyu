import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_buffer_phase.dart';
import 'package:yingyu/playback/rate_transition.dart';

void main() {
  test(
    'audio preparation preserves pitch algorithm and runs only before first load',
    () async {
      final settings = {'af': '', 'opensles-buffer-size-in-ms': '250'};
      final writes = <String>[];
      final setup = RateAudioSetup();
      Future<List<String>> prepare() => setup.prepare(
        read: (key) async => settings[key.substring(8)]!,
        write: (key, value) async {
          settings[key] = value;
          writes.add('$key=$value');
        },
      );
      await Future.wait([prepare(), prepare()]);
      await prepare();
      expect(writes, ['af=scaletempo2', 'opensles-buffer-size-in-ms=100']);
      expect(settings['af'], 'scaletempo2');
    },
  );
  test(
    'existing audio filters are kept and unsupported option leaves original settings',
    () async {
      final settings = {
        'af': 'synthetic-existing-filter',
        'opensles-buffer-size-in-ms': '250',
      };
      final writes = <String>[];
      final result = await RateAudioSetup().prepare(
        read: (key) async => settings[key.substring(8)]!,
        write: (key, value) async {
          writes.add('$key=$value');
          if (value == '100') throw StateError('synthetic rejected option');
          settings[key] = value;
        },
      );
      expect(writes, [
        'opensles-buffer-size-in-ms=100',
        'opensles-buffer-size-in-ms=250',
      ]);
      expect(settings['af'], 'synthetic-existing-filter');
      expect(settings['opensles-buffer-size-in-ms'], '250');
      expect(result.last, contains('优化未启用'));
    },
  );
  test(
    'same cache tier makes no native changes; changed tiers keep static toggles alone',
    () {
      DiscBufferPlan plan(double speed) => DiscBufferPlan(
        speed: speed,
        fast: false,
        baseBytes: 128 * 1048576,
        memoryMiB: 128,
      );
      expect(
        changedDiscOptions(plan(1.25).options, plan(1.5).options),
        isEmpty,
      );
      expect(changedDiscOptions(plan(1.5).options, plan(2).options), isEmpty);
      final higher = changedDiscOptions(plan(1).options, plan(3).options);
      expect(higher, {
        'cache-pause-wait': '24.00',
        'cache-secs': '180.00',
        'demuxer-max-bytes': '805306368',
      });
      expect(changedDiscOptions(null, plan(1).options), plan(1).options);
      expect(
        changedDiscOptions(
          plan(3).options,
          plan(1).options,
        )['cache-pause-wait'],
        '2.00',
      );
    },
  );
  testWidgets(
    'rate probes are bounded, sanitized, superseded and stop when disabled',
    (tester) async {
      final records = <String>[];
      var enabled = true;
      var reads = 0;
      final probe = RateSwitchProbe(
        read: (key) async {
          reads++;
          return key == 'time-pos'
              ? 'https://private.invalid/?token=secret'
              : key == 'paused-for-cache' || key == 'seeking'
              ? 'no'
              : '3.000000';
        },
        record: records.add,
        active: () => enabled,
      );
      probe.start(1, 3);
      await tester.pump(const Duration(milliseconds: 250));
      expect(records, hasLength(1));
      expect(records.single, contains('1.0→3.0'));
      expect(records.single, contains('time-pos=未提供'));
      expect(records.single, isNot(contains('private')));
      probe.start(3, 1.5);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(records, hasLength(9));
      final finishedReads = reads;
      await tester.pump(const Duration(seconds: 3));
      expect(reads, finishedReads);
      probe.start(1.5, 2);
      enabled = false;
      await tester.pump(const Duration(seconds: 3));
      expect(reads, finishedReads);
      probe.cancel();
    },
  );
  testWidgets(
    'cancellation drops an in-flight sample without overlapping reads',
    (tester) async {
      final records = <String>[];
      final pending = Completer<String>();
      var reads = 0;
      final probe = RateSwitchProbe(
        read: (_) {
          reads++;
          return pending.future;
        },
        record: records.add,
        active: () => true,
      );
      probe.start(1, 3);
      await tester.pump(const Duration(milliseconds: 250));
      probe.cancel();
      pending.complete('3');
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(records, isEmpty);
      expect(reads, 1);
    },
  );
}
