import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_timestamps.dart';
import 'package:yingyu/playback/phone_fit.dart';

void main() {
  test('ordinary resources never read or write the new disc option', () async {
    for (final kind in ['file', 'strm', '302', 'p8', 'audio']) {
      final setup = DiscCacheSetup();
      expect(
        await setup.prepare(
          disc: false,
          read: (_) => throw StateError(kind),
          write: (_, _) => throw StateError(kind),
        ),
        false,
      );
    }
  });
  for (final original in ['no', 'yes']) {
    test(
      'disc enable readback and ordinary-media restoration from $original',
      () async {
        final setup = DiscCacheSetup();
        var value = original;
        final writes = <String>[];
        Future<String> read(String key) async {
          expect(key, 'options/${DiscCacheSetup.option}');
          return value;
        }

        Future<void> write(String key, String next) async {
          expect(key, DiscCacheSetup.option);
          writes.add(next);
          value = next;
        }

        expect(await setup.prepare(disc: true, read: read, write: write), true);
        expect(value, 'yes');
        final count = writes.length;
        await setup.prepare(disc: true, read: read, write: write);
        expect(writes.length, count);
        await setup.prepare(disc: false, read: read, write: write);
        expect(value, original);
      },
    );
  }
  test(
    'failed confirmation restores original and reports the real failure',
    () async {
      final setup = DiscCacheSetup();
      var value = 'no';
      var lie = true;
      final writes = <String>[];
      Future<String> read(String key) async =>
          lie && value == 'yes' ? 'no' : value;
      Future<void> write(String key, String next) async {
        writes.add(next);
        value = next;
      }

      await expectLater(
        setup.prepare(disc: true, read: read, write: write),
        throwsStateError,
      );
      expect(writes, ['yes', 'no']);
      expect(value, 'no');
      lie = false;
      expect(await setup.prepare(disc: true, read: read, write: write), true);
    },
  );
  test('failed restoration retains snapshot for the next attempt', () async {
    final setup = DiscCacheSetup();
    var value = 'no';
    var fail = false;
    Future<String> read(String _) async => value;
    Future<void> write(String key, String next) async {
      if (fail && next == 'no') throw StateError('synthetic');
      value = next;
    }

    await setup.prepare(disc: true, read: read, write: write);
    fail = true;
    await expectLater(
      setup.prepare(disc: false, read: read, write: write),
      throwsStateError,
    );
    fail = false;
    await setup.prepare(disc: false, read: read, write: write);
    expect(value, 'no');
  });
  test(
    'unknown native capability is rejected without touching options',
    () async {
      final setup = DiscCacheSetup();
      var writes = 0;
      await expectLater(
        setup.prepare(
          disc: true,
          read: (_) async => '',
          write: (_, _) async {
            writes++;
          },
        ),
        throwsStateError,
      );
      expect(writes, 0);
    },
  );
  test('disc and successor ordinary operations are serialized', () async {
    final setup = DiscCacheSetup();
    var value = 'no';
    final writes = <String>[];
    Future<String> read(String _) async => value;
    Future<void> write(String key, String next) async {
      await Future<void>.delayed(Duration.zero);
      value = next;
      writes.add(next);
    }

    final a = setup.prepare(disc: true, read: read, write: write);
    final b = setup.prepare(disc: false, read: read, write: write);
    expect(await a, true);
    expect(await b, false);
    expect(writes, ['yes', 'no']);
  });
  for (final cache in [
    '0.2',
    '7.99',
    '5921.916',
    'NaN',
    'Infinity',
    'unknown',
    '-1',
  ]) {
    test('optional phone readback yields to unsafe cache $cache', () async {
      final reads = <String>[];
      expect(
        await phoneFitReadbackAllowed((key) async {
          reads.add(key);
          return cache;
        }),
        false,
      );
      expect(reads, ['demuxer-cache-duration']);
    });
  }
  for (final state in [
    ('8', 'no', 'no', true),
    ('120', 'no', 'no', true),
    ('20', 'yes', 'no', false),
    ('20', 'no', 'yes', false),
  ]) {
    test('phone readback uses actual cache/pause/seek state $state', () async {
      expect(
        await phoneFitReadbackAllowed(
          (key) async => {
            'demuxer-cache-duration': state.$1,
            'paused-for-cache': state.$2,
            'seeking': state.$3,
          }[key]!,
        ),
        state.$4,
      );
    });
  }
}
