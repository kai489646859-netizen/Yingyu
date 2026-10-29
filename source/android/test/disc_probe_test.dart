import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_startup.dart';

void main() {
  test(
    'disc nearby-probe buffer is restored before an ordinary file',
    () async {
      var value = '131072';
      final writes = <String>[];
      final setup = DiscProbeSetup();
      Future<String?> prepare(bool disc) => setup.prepare(
        disc: disc,
        read: (_) async => value,
        write: (_, v) async {
          value = v;
          writes.add(v);
        },
      );
      await prepare(false);
      expect(writes, isEmpty);
      await prepare(true);
      await prepare(true);
      expect(value, '4194304');
      await prepare(false);
      expect(value, '131072');
      expect(writes, ['4194304', '131072']);
      await prepare(true);
      expect(value, '4194304');
    },
  );
  test('existing larger stream buffers are preserved', () async {
    var value = '8388608';
    final setup = DiscProbeSetup();
    for (final disc in [true, false]) {
      await setup.prepare(
        disc: disc,
        read: (_) async => value,
        write: (_, v) async {
          value = v;
          fail('existing buffer replaced');
        },
      );
    }
  });
  test('silently rejected configuration is restored and reported', () async {
    final writes = <String>[];
    final result = await DiscProbeSetup().prepare(
      disc: true,
      read: (_) async => '131072',
      write: (_, v) async => writes.add(v),
    );
    expect(result, contains('未启用'));
    expect(writes, ['4194304', '131072']);
  });
  test(
    'failed restoration cannot be reported as a successful fallback',
    () async {
      var value = '131072';
      final setup = DiscProbeSetup();
      await setup.prepare(
        disc: true,
        read: (_) async => value,
        write: (_, v) async => value = v,
      );
      await expectLater(
        setup.prepare(
          disc: false,
          read: (_) async => value,
          write: (_, v) async {},
        ),
        throwsStateError,
      );
    },
  );
}
