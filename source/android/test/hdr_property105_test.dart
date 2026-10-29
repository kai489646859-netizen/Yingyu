import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'host/hdr105_current_io.dart';

void main() {
  test(
    'public runtime reads and writes receive acknowledged replies',
    () async {
      final io = OutputIo();
      io.mpv.value = 'gpu';
      expect(await io.getProperty('current-vo'), 'gpu');
      await io.setProperty('sub-visibility', 'yes');
      expect(io.mpv.written, 'yes');
      expect(io.mpv.synchronousCalls, 0);
      expect(io.pending, 0);
    },
  );
  test(
    'public runtime native refusal and missing properties remain visible',
    () async {
      final io = OutputIo();
      io.mpv.result = -3;
      await expectLater(io.getProperty('current-vo'), throwsStateError);
      await expectLater(io.setProperty('vo', 'gpu'), throwsStateError);
      expect(io.pending, 0);
      io.mpv.result = 0;
      io.mpv.missing = true;
      expect(await io.getProperty('missing'), '');
      expect(io.pending, 0);
    },
  );
  test(
    'public property deadlines and late replies do not leak pending requests',
    () {
      fakeAsync((clock) {
        final io = OutputIo();
        io.mpv.deferred = true;
        var failed = 0;
        io
            .getProperty('current-vo')
            .then(
              (_) {},
              onError: (Object _) {
                failed++;
              },
            );
        clock.flushMicrotasks();
        expect(io.pending, 1);
        clock.elapse(const Duration(seconds: 4));
        clock.flushMicrotasks();
        expect(failed, 1);
        expect(io.pending, 0);
        io.mpv.flush();
        clock.flushMicrotasks();
        expect(failed, 1);
        io
            .setProperty('vo', 'gpu')
            .then(
              (_) {},
              onError: (Object _) {
                failed++;
              },
            );
        clock.flushMicrotasks();
        clock.elapse(const Duration(seconds: 4));
        clock.flushMicrotasks();
        expect(failed, 2);
        expect(io.pending, 0);
        expect(io.mpv.synchronousCalls, 0);
        io.mpv.flush();
        clock.flushMicrotasks();
      });
    },
  );
  test(
    'disposal while waiting rejects the result without further native calls',
    () async {
      final io = OutputIo();
      io.mpv.deferred = true;
      final pending = io.getProperty('current-vo');
      final rejected = expectLater(pending, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      io.disposed = true;
      await io.mpv.flush();
      await rejected;
      expect(io.pending, 0);
      expect(io.mpv.calls, 1);
    },
  );
}
