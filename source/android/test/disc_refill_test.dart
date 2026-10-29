import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_speed_reader.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'disc_speed_reader_test.dart' show SourceFixture, checkBytes, mib;

Future<void> until(bool Function() condition) async {
  final deadline = Stopwatch()..start();
  while (!condition() && deadline.elapsedMilliseconds < 1500) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(
    condition(),
    true,
    reason: 'producer must refill without another read',
  );
}

void main() {
  test('a slow earlier range is not starved by faster future ranges', () async {
    final fixture = SourceFixture(delay: const Duration(milliseconds: 1));
    final reader = DiscSpeedReader(fixture.single, (
      path,
      start,
      end,
      identity,
      cancel,
    ) async {
      final source = await fixture.part(path, start, end, identity, cancel);
      return DiscStreamSource(
        start: source.start,
        total: source.total,
        identity: source.identity,
        close: source.close,
        bytes: source.bytes.asyncMap((chunk) async {
          if (start == 20 * mib) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return chunk;
        }),
      );
    }, partBytes: 8 * mib)..setSpeed(3);
    try {
      for (var at = 0; at < 64 * mib; at += 4 * mib) {
        await checkBytes(
          reader,
          at,
          4 * mib,
        ).timeout(const Duration(seconds: 3));
      }
      await checkBytes(reader, 64 * mib, 57);
      expect(fixture.peak, 2);
      expect(reader.peakPartBytes, lessThanOrEqualTo(16 * mib));
    } finally {
      await reader.close();
    }
  });

  for (final speed in [2.0, 3.0]) {
    test(
      '$speed x refills a free lane before an older range is consumed',
      () async {
        final fixture = SourceFixture(delay: const Duration(milliseconds: 1));
        final reader = DiscSpeedReader(
          fixture.single,
          fixture.part,
          partBytes: 8 * mib,
        )..setSpeed(speed);
        try {
          for (var at = 0; at <= 12 * mib; at += 4 * mib) {
            await checkBytes(reader, at, 4 * mib);
          }
          // 12..20 is still half unread. The consumer deliberately stops here.
          // After 20..28 finishes, 28..36 must start using recycled pages.
          await until(
            () => fixture.opened.any((r) => r.part && r.start == 28 * mib),
          );
          await until(() => reader.retainedBytes == 16 * mib);
          final opens = fixture.opened.length;
          await Future<void>.delayed(const Duration(milliseconds: 25));
          expect(
            fixture.opened.length,
            opens,
            reason: 'full cache applies backpressure',
          );
          expect(reader.peakPartBytes, lessThanOrEqualTo(16 * mib));
          for (var at = 16 * mib; at < 64 * mib; at += 4 * mib) {
            await checkBytes(reader, at, 4 * mib);
          }
          await checkBytes(reader, 64 * mib, 57);
          expect(fixture.peak, 2);
        } finally {
          await reader.close().timeout(const Duration(seconds: 2));
        }
        expect(fixture.active, 0);
        expect(reader.retainedBytes, 0);
      },
    );
  }

  for (final action in ['close', 'seek', 'lower', 'two']) {
    test(
      'full producer buffer supports $action without stale bytes or extra sockets',
      () async {
        final fixture = SourceFixture(delay: const Duration(milliseconds: 1));
        final reader = DiscSpeedReader(
          fixture.single,
          fixture.part,
          partBytes: 8 * mib,
        )..setSpeed(3);
        try {
          for (var at = 0; at <= 12 * mib; at += 4 * mib) {
            await checkBytes(reader, at, 4 * mib);
          }
          await until(() => reader.retainedBytes == 16 * mib);
          if (action == 'seek') {
            await checkBytes(reader, 48 * mib, 4 * mib);
            await checkBytes(reader, 0, 4 * mib);
          } else if (action != 'close') {
            reader.setSpeed(action == 'two' ? 2 : 1);
            final partCount = fixture.partNumber;
            for (var at = 16 * mib; at < 64 * mib; at += 4 * mib) {
              await checkBytes(reader, at, 4 * mib);
            }
            if (action == 'two') {
              expect(fixture.partNumber, greaterThan(partCount));
            } else {
              expect(
                fixture.partNumber,
                partCount,
                reason: 'drain existing bytes after lowering',
              );
            }
          }
          expect(fixture.peak, lessThanOrEqualTo(2));
          expect(reader.peakPartBytes, lessThanOrEqualTo(16 * mib));
        } finally {
          await reader.close().timeout(const Duration(seconds: 2));
        }
        expect(fixture.active, 0);
        expect(reader.retainedBytes, 0);
      },
    );
  }
}
