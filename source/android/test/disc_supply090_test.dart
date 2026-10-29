import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_ordered_reader.dart';
import 'disc_speed_reader_test.dart' show SourceFixture, mib;

Future<void> drain(DiscOrderedReader reader, int total) async {
  for (var at = 0; at < total;) {
    final block = await reader.read(
      '',
      at,
      (total - at).clamp(0, mib),
      DiscReadCancellation(),
    );
    expect(block.start, at);
    expect(block.bytes.length, (total - at).clamp(0, mib));
    // Check every byte, including all boundaries across mixed packet streams.
    for (var i = 0; i < block.bytes.length;) {
      final count = (256 * 1024 - (at + i) % (256 * 1024)).clamp(
        0,
        block.bytes.length - i,
      );
      expect(
        block.bytes.sublist(i, i + count),
        everyElement(((at + i) ~/ (256 * 1024)) % 251),
      );
      i += count;
    }
    expect(reader.retainedBytes, lessThanOrEqualTo(48 * mib));
    expect(reader.activeResponses, lessThanOrEqualTo(2));
    at += block.bytes.length;
  }
}

void main() {
  test(
    'small configured queue keeps single input without negative capacity',
    () async {
      final source = SourceFixture(total: 12 * mib + 57);
      final reader = DiscOrderedReader(
        source.single,
        openPart: source.part,
        maxBytes: 4 * mib,
      )..setSpeed(3);
      try {
        await drain(reader, source.total);
        expect(source.partNumber, 0);
        expect(reader.retainedBytes, lessThanOrEqualTo(4 * mib));
      } finally {
        await reader.close();
      }
    },
  );
  test(
    'actual ordered producer falls back after shared capacity gives no gain',
    () async {
      final messages = <String>[];
      final source = SourceFixture(
        total: 64 * mib + 57,
        sharedLimit: true,
        delay: const Duration(milliseconds: 30),
      );
      final reader = DiscOrderedReader(
        source.single,
        openPart: source.part,
        maxBytes: 48 * mib,
        onDiagnostic: messages.add,
      )..setSpeed(3);
      try {
        await drain(reader, source.total);
        expect(
          messages.any((s) => s.contains('1.1 倍')),
          true,
          reason: '${messages.join("\n")}\n${reader.deliveryHealth}',
        );
        expect(reader.mode, contains('退回'));
        expect(source.peak, lessThanOrEqualTo(2));
      } finally {
        await reader.close();
      }
    },
  );
  for (final hint in ['3x', 'starved', 'normal', 'unqualified']) {
    test('actual ordered data path exact EOF with $hint', () async {
      final source = SourceFixture(
        qualified: hint != 'unqualified',
        total: 40 * mib + 57,
        delay: const Duration(milliseconds: 1),
      );
      final reader = DiscOrderedReader(
        source.single,
        openPart: source.part,
        maxBytes: 48 * mib,
      );
      if (hint == '3x' || hint == 'unqualified') reader.setSpeed(3);
      if (hint == 'starved') reader.setBuffering(true);
      try {
        await drain(reader, source.total);
        expect(source.peak, lessThanOrEqualTo(2));
        expect(source.partNumber > 0, hint == '3x');
      } finally {
        await reader.close();
      }
      expect(source.active, 0);
    });
  }
  test('small metadata demands do not start parallel reads', () async {
    final source = SourceFixture();
    final reader = DiscOrderedReader(
      source.single,
      openPart: source.part,
      maxBytes: 48 * mib,
    )..setSpeed(3);
    try {
      await reader.read('', 0, 64 * 1024, DiscReadCancellation());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(source.partNumber, 0);
      expect(reader.retainedBytes, lessThanOrEqualTo(64 * 1024));
    } finally {
      await reader.close();
    }
  });
  for (final failure in ['warmup', 'changed', 'body', 'twice']) {
    test(
      'ordered path preserves fallback and real failures: $failure',
      () async {
        final source = SourceFixture(
          total: 40 * mib + 57,
          failPart: failure == 'warmup' ? 1 : null,
          changedPart: failure == 'changed' ? 1 : null,
          cutPart: failure == 'body' || failure == 'twice' ? 2 : null,
          cutRecovery: failure == 'twice',
          delay: const Duration(milliseconds: 1),
        );
        final reader = DiscOrderedReader(
          source.single,
          openPart: source.part,
          maxBytes: 48 * mib,
        )..setSpeed(3);
        try {
          if (failure == 'changed' || failure == 'twice') {
            await expectLater(
              drain(reader, source.total),
              throwsA(isA<AppFailure>()),
            );
          } else {
            await drain(reader, source.total);
          }
          expect(source.peak, lessThanOrEqualTo(2));
          expect(
            source.opened.where((r) => !r.part).length,
            lessThanOrEqualTo(2),
          );
        } finally {
          await reader.close();
        }
        expect(source.active, 0);
      },
    );
  }
  test(
    'full two-lane queue cancels and seeks without stale bytes or sockets',
    () async {
      final source = SourceFixture(total: 80 * mib + 57);
      final reader = DiscOrderedReader(
        source.single,
        openPart: source.part,
        maxBytes: 48 * mib,
      )..setSpeed(3);
      try {
        for (var at = 0; at < 10 * mib; at += mib) {
          await reader.read('', at, mib, DiscReadCancellation());
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(reader.retainedBytes, lessThanOrEqualTo(48 * mib));
        reader.setSpeed(1);
        reader.setBuffering(false);
        final block = await reader.read(
          '',
          72 * mib,
          mib,
          DiscReadCancellation(),
        );
        expect(block.bytes.first, (72 * mib ~/ (256 * 1024)) % 251);
        expect(block.bytes.last, (73 * mib - 1) ~/ (256 * 1024) % 251);
      } finally {
        await reader.close();
      }
      expect(source.active, 0);
    },
  );
}
