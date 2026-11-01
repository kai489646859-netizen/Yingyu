import 'package:flutter_test/flutter_test.dart';
import 'host/stability206/old/ffi.dart' as old;
import 'host/stability206/new/ffi.dart' as current;

void main() {
  const baseline = bool.fromEnvironment('STABILITY206_OLD');
  dynamic make() => baseline ? old.Io206() : current.Io206();
  if (!baseline) {
    test(
      'command vector retains every argument and its null terminator',
      () async {
        final io = current.Io206();
        addTearDown(io.calloc.clean);
        final args = List.generate(512, (i) => 'value$i');
        await io.command(args);
        expect(io.mpv.commandArgs, args);
        expect(io.pending, 0);
        expect(io.calloc.live, isEmpty);
      },
    );
  }
  test(
    'rejected native requests release memory and pending records after 10000 commands',
    () async {
      final io = make();
      addTearDown(() => io.calloc.clean());
      io.mpv.immediate = -4;
      for (var i = 0; i < 2000; i++) {
        await io.flag();
        await io.number();
        await io.integer();
        await io.string();
        await io.command(['seek', '42', 'absolute+exact']);
      }
      expect(io.mpv.calls, 10000);
      expect(io.errors.length, 10000);
      expect(
        io.calloc.live,
        isEmpty,
        reason: 'native allocations retained after immediate rejection',
      );
      expect(io.pending, 0);
    },
  );
  test(
    'synchronous property calls never accumulate asynchronous waiters',
    () async {
      final io = make();
      addTearDown(() => io.calloc.clean());
      io.configuration.async = false;
      for (var i = 0; i < 10000; i++) {
        await io.number();
      }
      expect(io.calloc.live, isEmpty);
      expect(io.pending, 0);
    },
  );
  test(
    'bridge exceptions release every property and command allocation',
    () async {
      final io = make();
      addTearDown(() => io.calloc.clean());
      io.mpv.throws = true;
      for (final action in [
        () => io.flag(),
        () => io.number(),
        () => io.integer(),
        () => io.string(),
        () => io.command(['seek', '0', 'absolute+exact']),
      ]) {
        await expectLater(action(), throwsStateError);
      }
      expect(io.calloc.live, isEmpty);
      expect(io.pending, 0);
    },
  );
  test(
    'accepted operations wait for real replies and preserve errors and output epoch',
    () async {
      final io = make();
      addTearDown(() => io.calloc.clean());
      io.mpv.hold = true;
      var done = false;
      final future = io.command(['seek', '42.5', 'absolute+exact']).then((_) {
        done = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(done, false);
      expect(io.pending, 1);
      expect(io.outputEpoch, 1);
      expect(io.mpv.commandArgs, ['seek', '42.5', 'absolute+exact']);
      (io.mpv.waiting.removeAt(0) as void Function())();
      await future;
      io.mpv.hold = false;
      io.mpv.result = -5;
      await io.flag();
      await io.number();
      await io.integer();
      await io.string();
      await io.command(['cycle', 'pause']);
      expect(io.outputEpoch, 1);
      expect(io.errors, [-5, -5, -5, -5, -5]);
      expect(io.mpv.properties, ['pause', 'speed', 'aid', 'sid']);
      expect(io.calloc.live, isEmpty);
      expect(io.pending, 0);
    },
  );
}
