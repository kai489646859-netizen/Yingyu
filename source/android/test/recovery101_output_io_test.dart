// Flutter's pinned test runtime supplies this clock for deadline-only IO tests.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'host/recovery101_output_io.dart';
import 'host/recovery101_old_fixture.dart' as old;
import 'hdr_recovery101_test.dart' show RealOutputFixture;

void main() {
  test(
    'native string reads copy reply data before native event memory expires',
    () async {
      final io = OutputIo();
      io.mpv.value = 'bt.2020';
      expect(await io.getOutputProperty('options/target-prim'), 'bt.2020');
      expect(io.mpv.property, 'options/target-prim');
      expect(io.pending, 0);
      await io.setOutputProperty('target-trc', 'pq');
      expect(io.mpv.written, 'pq');
      expect(io.pending, 0);
    },
  );
  test(
    'native refusal and reply errors are real failures with no leaked requests',
    () async {
      final io = OutputIo();
      io.mpv.result = -3;
      await expectLater(io.setOutputProperty('vo', 'gpu'), throwsStateError);
      await expectLater(io.getOutputProperty('current-vo'), throwsStateError);
      expect(io.pending, 0);
      io.mpv.result = 0;
      io.mpv.error = -10;
      await expectLater(io.setOutputProperty('vo', 'gpu'), throwsStateError);
      expect(await io.getOutputProperty('current-vo'), '');
      expect(io.pending, 0);
      io.mpv.error = 0;
      io.mpv.missing = true;
      expect(await io.getOutputProperty('current-vo'), '');
      expect(io.pending, 0);
    },
  );
  test(
    'late replies after the four second deadline cannot complete a newer request',
    () {
      fakeAsync((clock) {
        final io = OutputIo();
        io.mpv.deferred = true;
        var errors = 0;
        String? value;
        io
            .getOutputProperty('current-vo')
            .then<void>(
              (v) {
                value = v;
              },
              onError: (Object _) {
                errors++;
              },
            );
        clock.elapse(const Duration(seconds: 4));
        clock.flushMicrotasks();
        expect(errors, 1);
        expect(io.pending, 0);
        io.mpv.flush();
        clock.flushMicrotasks();
        expect(value, isNull);
        expect(errors, 1);
        io
            .setOutputProperty('vo', 'gpu')
            .then(
              (_) {},
              onError: (Object _) {
                errors++;
              },
            );
        clock.elapse(const Duration(seconds: 4));
        clock.flushMicrotasks();
        expect(errors, 2);
        expect(io.pending, 0);
        io.mpv.flush();
        clock.flushMicrotasks();
        expect(errors, 2);
      });
    },
  );
  test(
    'disposal rejects new IO and invalidates an outstanding native result',
    () async {
      final io = OutputIo();
      io.mpv.deferred = true;
      final future = io.getOutputProperty('current-vo');
      final rejected = expectLater(future, throwsStateError);
      io.disposed = true;
      await io.mpv.flush();
      await rejected;
      expect(io.pending, 0);
      await expectLater(io.getOutputProperty('current-vo'), throwsStateError);
      await expectLater(io.setOutputProperty('vo', 'gpu'), throwsStateError);
      expect(io.mpv.calls, 1);
    },
  );
  test(
    'whole delivered transaction falsely accepts restored options without video',
    () async {
      final f = old.RealOutputFixture();
      expect(await f.apply(), false);
      expect(f.selected, false);
      expect(f.actualVo, '');
      expect(f.output.active, false);
      final repaired = RealOutputFixture();
      expect(await repaired.apply(), false);
      expect(repaired.selected, true);
      expect(repaired.actualVo, 'gpu');
      expect(repaired.output.active, false);
    },
  );
  test(
    'whole delivered transaction also accepts a VO without a frame',
    () async {
      final f = old.RealOutputFixture()
        ..loseVideo = false
        ..noRestoredFrame = true;
      expect(await f.apply(), false);
      expect(f.actualVo, 'gpu');
      expect(f.output.active, false);
      final repaired = RealOutputFixture()
        ..loseVideo = false
        ..noRestoredFrame = true;
      await expectLater(repaired.apply(), throwsStateError);
      expect(repaired.output.active, true);
    },
  );
}
