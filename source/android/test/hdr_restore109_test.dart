import 'package:flutter_test/flutter_test.dart';
import 'hdr_warmup106_test.dart' show WarmupFixture;

// Replay the exported state boundary: rejected HDR, then a configured
// compatibility renderer still doing its exact seek with no frame yet.
// Timings are synthetic; this is not a device decoder benchmark.
class Restore109Fixture extends WarmupFixture {
  int restoreDelay = 4500;
  bool restoring = false, knownRestore = true, configuredRestore = true;
  int? cancelRestoreAt;
  int? closeRestoreAt;

  @override
  Future<void> refresh(String position) async {
    await super.refresh(position);
    if (!hdr) restoring = true;
  }

  @override
  Future<void> wait(Duration duration) async {
    await super.wait(duration);
    if (restoring && cancelRestoreAt != null && elapsed >= cancelRestoreAt!) {
      current = false;
    }
    if (restoring && closeRestoreAt != null && elapsed >= closeRestoreAt!) {
      output.cancelForClose();
    }
  }

  @override
  Future<String> read(String key) async {
    if (!restoring) return super.read(key);
    if (key == 'vo-configured') {
      return knownRestore ? (configuredRestore ? 'yes' : 'no') : '';
    }
    if (key == 'seeking') {
      return knownRestore ? (elapsed >= restoreDelay ? 'no' : 'yes') : '';
    }
    if (key == 'video-frame-info/interlaced') {
      return elapsed >= restoreDelay ? 'no' : '';
    }
    return super.read(key);
  }
}

void main() {
  for (final delay in [3600, 6500]) {
    test(
      'configured fallback survives exact refill lasting $delay ms',
      () async {
        final f = Restore109Fixture()
          ..readyAfter = 999999
          ..restoreDelay = delay;
        expect(await f.apply(), false);
        expect(f.output.active, false);
        expect(f.options['wid'], '900');
        expect(f.options['target-trc'], 'bt.1886');
        expect(f.output.status, contains('compatible-ready'));
        expect(f.refills, 2);
        expect(f.elapsed, lessThan(delay + 100));
        expect(
          f.writes.where(
            (e) => {'pause', 'aid', 'sid', 'loadfile'}.contains(e.$1),
          ),
          isEmpty,
        );
      },
    );
  }
  test(
    'permanent configured fallback still fails within eight seconds',
    () async {
      final f = Restore109Fixture()
        ..readyAfter = 999999
        ..restoreDelay = 999999;
      await expectLater(f.apply(), throwsStateError);
      expect(f.output.active, true);
      expect(f.elapsed, lessThanOrEqualTo(8000));
    },
  );
  for (final unknown in [true, false]) {
    test(
      'unknown or unconfigured fallback keeps short bound: $unknown',
      () async {
        final f = Restore109Fixture()
          ..readyAfter = 999999
          ..restoreDelay = 999999
          ..knownRestore = !unknown
          ..configuredRestore = false;
        await expectLater(f.apply(), throwsStateError);
        expect(f.elapsed, lessThanOrEqualTo(3000));
      },
    );
  }
  test('new intent stops fallback wait promptly', () async {
    final f = Restore109Fixture()
      ..readyAfter = 999999
      ..cancelRestoreAt = 200;
    expect(await f.apply(), false);
    expect(f.elapsed, lessThan(300));
    expect(f.output.status, contains('superseded'));
  });
  test('closing during fallback detaches without another refill', () async {
    final f = Restore109Fixture()
      ..readyAfter = 999999
      ..closeRestoreAt = 200;
    expect(await f.apply(), false);
    expect(f.elapsed, lessThan(300));
    expect(f.output.active, false);
    expect(f.output.status, 'closed-detached');
    expect(f.options['wid'], '0');
    expect(f.refills, 2);
  });
}
