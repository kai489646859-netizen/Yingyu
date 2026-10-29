import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_timestamps.dart';
import 'host/replay075/health.dart';
import 'host/replay075/surfaces.dart';

void main() {
  test(
    'complete production health method: same-sample recovery beats audio deadline',
    () async {
      for (final h in <HealthHarness>[OldHealth(), CurrentHealth()]) {
        h.fault(0);
        await h.sampleAt(0, 15.3, 15.3, buffering: true);
        for (final n in [2, 4, 6, 8]) {
          await h.sampleAt(n, 0, 15 + n.toDouble());
        }
        expect(h.repairs, h is OldHealth ? 0 : 1);
        expect(h.failure, h is OldHealth ? isNotNull : isNull);
        if (h is CurrentHealth) {
          expect(h.pendingAudio, true);
          await h.sampleAt(10, 13, 13);
          await h.sampleAt(12, 15, 15);
          expect(h.pendingAudio, false);
          expect(h.recovering, false);
          expect(h.failure, isNull);
        }
      }
    },
  );
  test(
    'new order still fails at bounded video deadline and preserves repeated audio failure',
    () async {
      final h = CurrentHealth()..fault(0);
      await h.sampleAt(0, 15, 15, buffering: true);
      for (final n in [2, 4, 6, 8, 10, 20, 30, 40]) {
        await h.sampleAt(n, 0, 15 + n.toDouble());
      }
      expect(h.failure, contains('视频时钟持续停滞'));
      expect(h.repairs, 1);
      final repeated = CurrentHealth()..fault(0, count: 8);
      await repeated.sampleAt(0, 10, 10);
      expect(repeated.failure, contains('音频解码错误'));
    },
  );
  test(
    'normal advancing video/audio and user pause do not cause recovery',
    () async {
      final normal = CurrentHealth();
      for (final n in [0, 2, 4, 8, 20]) {
        await normal.sampleAt(n, 40 + n.toDouble(), 40 + n.toDouble());
      }
      expect(normal.repairs, 0);
      expect(normal.failure, isNull);
      final paused = CurrentHealth()..fault(0);
      for (final n in [0, 2, 50, 100]) {
        await paused.sampleAt(n, 40, 40, playing: false);
      }
      expect(paused.failure, isNull);
      expect(paused.repairs, 0);
    },
  );
  test(
    'actual listeners: placeholder-to-first-size does not issue a second resume seek',
    () async {
      final before = OldSurface(), after = CurrentSurface();
      for (final dynamic h in [before, after]) {
        h.rect.value!.width = 1.0;
        h.rect.value!.height = 1.0;
        h.platform.values.addAll({
          'video-frame-info/interlaced': 'unavailable',
        });
        await h.widListener();
        h.rect.value!.width = 3840.0;
        h.rect.value!.height = 2160.0;
        h.platform.values.addAll({
          'video-frame-info/interlaced': 'no',
          'seeking': 'no',
          'idle-active': 'no',
          'time-pos': '41.916',
        });
        await h.widListener();
      }
      expect(before.player.seeks, [const Duration(milliseconds: 41916)]);
      expect(after.player.seeks, isEmpty);
      expect(after.writes, before.writes);
      // A later genuine replacement (including pause/background restore) keeps
      // the previous refresh path and still respects an in-flight user seek.
      after.wid.value = 0;
      await after.widListener();
      after.wid.value = 456;
      await after.widListener();
      expect(after.player.seeks, [const Duration(milliseconds: 41916)]);
      after.platform.values['seeking'] = 'yes';
      after.wid.value = 789;
      await after.widListener();
      expect(after.player.seeks.length, 1);
    },
  );
  for (final original in [
    '',
    'protocol_whitelist=[file,http,https],strict=experimental,skip_estimate_duration_from_pts=1',
  ]) {
    test(
      'disc timestamp setup preserves map and restores before ordinary media: $original',
      () async {
        var value = original;
        var decoder = 'no';
        final commands = <List<String>>[];
        final setup = DiscTimestampSetup();
        Future<String?> prepare(bool disc) => setup.prepare(
          disc: disc,
          read: (key) async =>
              key == 'options/vd-lavc-yingyu-disc-pts' ? decoder : value,
          command: (args) async {
            commands.add(args);
            if (args.first == 'set') {
              decoder = args.last;
              return;
            }
            value = args[2] == 'append'
                ? (value.isEmpty ? args.last : '$value,${args.last}')
                : original;
          },
        );
        await prepare(false);
        expect(commands, isEmpty);
        await Future.wait([prepare(true), prepare(true)]);
        expect(commands.where((args) => args.first == 'change-list').length, 1);
        expect(value, endsWith('fflags=+genpts'));
        expect(decoder, 'yes');
        await prepare(false);
        expect(value, original);
        expect(decoder, 'no');
        await prepare(true);
        expect(commands.where((args) => args.first == 'change-list').length, 3);
      },
    );
  }
  test('explicit flags are never overridden', () async {
    final commands = <List<String>>[];
    var decoder = 'no';
    await DiscTimestampSetup().prepare(
      disc: true,
      read: (key) async => key == 'options/vd-lavc-yingyu-disc-pts'
          ? decoder
          : 'fflags=+discardcorrupt',
      command: (args) async {
        commands.add(args);
        if (args.first == 'set') decoder = args.last;
      },
    );
    expect(commands, [
      ['set', 'vd-lavc-yingyu-disc-pts', 'yes'],
    ]);
  });
  for (final mismatch in [false, true]) {
    test(
      'timestamp command rejection restores exactly or reports failed rollback $mismatch',
      () async {
        var value = 'protocol_whitelist=[file,http]';
        var decoder = 'no';
        final original = value;
        final call = DiscTimestampSetup().prepare(
          disc: true,
          read: (key) async =>
              key == 'options/vd-lavc-yingyu-disc-pts' ? decoder : value,
          command: (a) async {
            if (a.first == 'set') {
              decoder = a.last;
              return;
            }
            if (a[2] == 'append') {
              value = 'unexpected';
              throw StateError('synthetic');
            }
            if (!mismatch) value = original;
          },
        );
        if (mismatch) {
          await expectLater(call, throwsStateError);
        } else {
          expect(await call, contains('未启用'));
          expect(value, original);
        }
      },
    );
  }
}
