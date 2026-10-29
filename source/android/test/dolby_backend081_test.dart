import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/dolby_recovery.dart';
import 'package:yingyu/playback/dolby_source.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'host/dolby081/backend.dart';

Duration ms(int value) => Duration(milliseconds: value);

List<String> hardwareWrites(DolbyBackendHarness value) => value.native.commands
    .where((command) => command.startsWith('write:hwdec='))
    .toList();

Future<DolbyBackendHarness> seeking({String hardware = 'mediacodec'}) async {
  final value = DolbyBackendHarness();
  value.native.values['hwdec-current'] = hardware;
  await value.seek(ms(80000));
  value.at(8);
  return value;
}

RuntimeSample unavailable(int now, {bool playing = true}) => RuntimeSample(
  now: ms(now),
  position: ms(80000),
  audioPosition: ms(79980),
  playing: playing,
  buffering: true,
  seeking: true,
  cachePaused: true,
  outputReady: false,
  hardware: 'mediacodec',
);

void main() {
  test(
    'complete handler rebuilds only observed hardware at the exact target',
    () async {
      final value = await seeking();
      expect(value.recovery.target, ms(80000));
      expect(value.seekSince, Duration.zero);
      await value.fault(DolbyOutputFailure.mapping);
      expect(hardwareWrites(value), ['write:hwdec=mediacodec']);
      expect(value.player.seeks, [ms(80000), ms(80000)]);
      expect(value.position, ms(80000));
      expect(value.recovery.recovering, isTrue);
      expect(value.recovery.repairing, isFalse);
      expect(value.busy, isFalse);
      expect(value.failure, isNull);
      expect(value.logs.any((row) => row.contains('命令完成不代表恢复成功')), isTrue);
      expect(value.logs.any((row) => row.contains('恢复已核对')), isFalse);
      expect(value.player.playCalls, 0);
      expect(value.player.pauseCalls, 0);
      expect(value.player.openCalls, 0);
    },
  );

  test(
    'mediacodec-copy is preserved instead of forcing another decoder',
    () async {
      final value = await seeking(hardware: 'mediacodec-copy');
      await value.fault(DolbyOutputFailure.mapping);
      expect(hardwareWrites(value), ['write:hwdec=mediacodec-copy']);
      expect(value.player.openCalls, 0);
    },
  );

  test('a paused user seek stays paused during and after rebuilding', () async {
    final value = await seeking();
    value.setPlaying(false);
    await value.fault(DolbyOutputFailure.mapping);
    expect(value.player.state.playing, isFalse);
    expect(value.player.playCalls, 0);
    expect(value.player.pauseCalls, 0);
    expect(
      value.recovery.sample(
        unavailable(60000, playing: false),
        generation: value.recovery.generation,
        speed: 1,
      ),
      DolbyRecoveryAction.none,
    );
    expect(value.recovery.recovering, isTrue);
  });

  for (final issue in [
    DolbyOutputFailure.pairing,
    DolbyOutputFailure.capability,
  ]) {
    test(
      'confirmed $issue remains fatal without a reconstruction grace period',
      () async {
        final value = await seeking();
        await value.fault(
          issue,
          code: issue == DolbyOutputFailure.pairing
              ? 'surface_timestamp'
              : 'raw_yuv_capability',
        );
        expect(value.failure, isNotNull);
        expect(value.failures, hasLength(1));
        expect(value.recovery.recovering, isFalse);
        expect(hardwareWrites(value), isEmpty);
        expect(value.player.seeks, [ms(80000)]);
      },
    );
  }

  test(
    'mapping outside a confirmed seek, while opening, or with unknown hardware fails',
    () async {
      final outside = DolbyBackendHarness();
      await outside.fault(DolbyOutputFailure.mapping);
      expect(outside.failure, isNotNull);
      final opening = await seeking();
      opening.setOpening(true);
      await opening.fault(DolbyOutputFailure.mapping);
      expect(opening.failure, isNotNull);
      for (final hardware in ['', 'no', 'auto']) {
        final value = await seeking(hardware: hardware);
        await value.fault(DolbyOutputFailure.mapping);
        expect(value.failure, isNotNull);
        expect(hardwareWrites(value), isEmpty);
      }
    },
  );

  test(
    'fresh hardware disagreement fails before any option mutation',
    () async {
      final value = await seeking();
      value.native.values['hwdec-current'] = 'mediacodec-copy';
      await value.fault(DolbyOutputFailure.mapping);
      expect(value.failure, isNotNull);
      expect(hardwareWrites(value), isEmpty);
      expect(value.player.seeks, [ms(80000)]);
      expect(value.busy, isFalse);
    },
  );

  test('a failed fresh hardware read remains a playback failure', () async {
    final value = await seeking();
    value.native.beforeRead = (_) async =>
        throw StateError('synthetic IO fault');
    await value.fault(DolbyOutputFailure.mapping);
    expect(value.failure, isNotNull);
    expect(hardwareWrites(value), isEmpty);
    expect(value.player.seeks, [ms(80000)]);
  });

  test(
    'a failed actual rebuild is fatal and releases the repair lock',
    () async {
      final value = await seeking();
      value.native.beforeWrite = (key, _) async {
        if (key == 'hwdec') throw StateError('synthetic IO fault');
      };
      await value.fault(DolbyOutputFailure.mapping);
      expect(value.failure, isNotNull);
      expect(value.recovery.recovering, isFalse);
      expect(value.busy, isFalse);
      expect(value.player.seeks, [ms(80000)]);
      expect(value.player.openCalls, 0);
    },
  );

  test(
    'queued duplicate mapping errors cannot become a second reconstruction',
    () async {
      final value = await seeking();
      final entered = Completer<void>(), release = Completer<void>();
      value.native.beforeRead = (key) async {
        if (key != 'hwdec-current') return;
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final first = value.fault(DolbyOutputFailure.mapping);
      await entered.future;
      await value.fault(DolbyOutputFailure.mapping);
      expect(value.failure, isNull);
      release.complete();
      await first;
      expect(hardwareWrites(value), ['write:hwdec=mediacodec']);
      expect(value.player.seeks, [ms(80000), ms(80000)]);
      await value.fault(DolbyOutputFailure.mapping);
      expect(value.failure, isNotNull);
      expect(hardwareWrites(value), ['write:hwdec=mediacodec']);
    },
  );

  test(
    'a newer production seek cancels a recovery still waiting in the rate queue',
    () async {
      final value = await seeking();
      final release = Completer<void>();
      final blocked = value.hold(release.future);
      final repair = value.fault(DolbyOutputFailure.mapping);
      final latest = value.seek(ms(30000));
      release.complete();
      await blocked;
      await repair;
      await latest;
      expect(hardwareWrites(value), isEmpty);
      expect(value.player.seeks, [ms(80000), ms(30000)]);
      expect(value.recovery.target, ms(30000));
      expect(value.recovery.attempted, isTrue);
      expect(value.failure, isNull);
      expect(value.busy, isFalse);
    },
  );

  test(
    'an expired rate queue fails before any decoder or seek command',
    () async {
      final value = await seeking();
      final release = Completer<void>();
      final blocked = value.hold(release.future);
      final repair = value.fault(DolbyOutputFailure.mapping);
      value.at(30000);
      release.complete();
      await blocked;
      await repair;
      expect(value.failure, isNotNull);
      expect(hardwareWrites(value), isEmpty);
      expect(value.player.seeks, [ms(80000)]);
      expect(value.busy, isFalse);
    },
  );

  test(
    'a newer production seek cancels the old target after its decoder write',
    () async {
      final value = await seeking();
      final entered = Completer<void>(), release = Completer<void>();
      value.native.beforeWrite = (key, _) async {
        if (key != 'hwdec') return;
        entered.complete();
        await release.future;
      };
      final repair = value.fault(DolbyOutputFailure.mapping);
      await entered.future;
      expect(value.busy, isTrue);
      final latest = value.seek(ms(30000));
      release.complete();
      await repair;
      await latest;
      expect(value.player.seeks, [ms(80000), ms(30000)]);
      expect(value.recovery.target, ms(30000));
      expect(value.recovery.attempted, isTrue);
      expect(value.failure, isNull);
      expect(value.busy, isFalse);
    },
  );

  for (final transition in ['close', 'new media', 'interrupt', 'fatal']) {
    test(
      '$transition while the hardware read waits prevents stale commands',
      () async {
        final value = await seeking();
        final entered = Completer<void>(), release = Completer<void>();
        value.native.beforeRead = (key) async {
          if (key != 'hwdec-current') return;
          entered.complete();
          await release.future;
        };
        final repair = value.fault(DolbyOutputFailure.mapping);
        await entered.future;
        switch (transition) {
          case 'close':
            value.close();
          case 'new media':
            value.invalidateMedia();
          case 'interrupt':
            value.interrupt();
          case 'fatal':
            value.fatal('prior synthetic terminal failure');
        }
        release.complete();
        await repair;
        expect(hardwareWrites(value), isEmpty);
        expect(value.player.seeks, [ms(80000)]);
        expect(value.busy, isFalse);
        expect(value.player.openCalls, 0);
      },
    );
  }

  test(
    'a late mapping failure does not reset the original seek deadline',
    () async {
      final value = await seeking();
      value.at(25000);
      await value.fault(DolbyOutputFailure.mapping);
      expect(value.seekSince, Duration.zero);
      expect(
        value.recovery.sample(
          unavailable(30000),
          generation: value.recovery.generation,
          speed: 1,
        ),
        DolbyRecoveryAction.fail,
      );
    },
  );

  test(
    'a normal media seek keeps its production seek and never arms Dolby recovery',
    () async {
      final value = DolbyBackendHarness()..ordinaryMedia();
      await value.seek(ms(12000));
      expect(value.player.seeks, [ms(12000)]);
      expect(value.recovery.recovering, isFalse);
      expect(
        value.native.commands.where((v) => v == 'read:hwdec-current'),
        isEmpty,
      );
      expect(hardwareWrites(value), isEmpty);
    },
  );
}
