import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_ordered_reader.dart';
import 'package:yingyu/playback/disc_stream.dart';

const mib = 1024 * 1024;
const chunk = DiscOrderedReader.chunkBytes;

class Source {
  int opens = 0, active = 0, peak = 0, received = 0;
  int total = 16 * mib;
  int? failAt;
  Completer<void>? gate;
  final starts = <int>[];
  Future<DiscStreamSource> open(
    String path,
    int start,
    DiscReadCancellation cancellation,
  ) async {
    opens++;
    active++;
    starts.add(start);
    if (active > peak) peak = active;
    var closed = false;
    Stream<List<int>> body() async* {
      for (var at = start; at < total && !closed; at += chunk) {
        if (gate != null) await gate!.future;
        if (closed) break;
        if (failAt != null && at >= failAt!) {
          throw StateError('synthetic read failure');
        }
        final size = (total - at).clamp(0, chunk);
        final bytes = Uint8List(size);
        for (var i = 0; i < size; i++) {
          bytes[i] = (at ~/ chunk + i) % 251;
        }
        received += size;
        yield bytes;
      }
    }

    return DiscStreamSource(
      start: start,
      total: total,
      bytes: body(),
      close: (_) {
        if (!closed) {
          closed = true;
          active--;
        }
        final pending = gate;
        if (pending != null && !pending.isCompleted) pending.complete();
      },
    );
  }
}

Future<void> until(bool Function() ready) async {
  for (var i = 0; i < 300 && !ready(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(ready(), isTrue);
}

void main() {
  test(
    'native available-only read delivers first chunk while the rest waits',
    () async {
      final gate = Completer<void>();
      final reader = DiscOrderedReader((path, start, token) async {
        Stream<List<int>> bytes() async* {
          yield Uint8List(chunk)..fillRange(0, chunk, 19);
          await gate.future;
          yield Uint8List(chunk)..fillRange(0, chunk, 23);
        }

        return DiscStreamSource(
          start: 0,
          total: 2 * chunk,
          bytes: bytes(),
          close: (_) {
            if (!gate.isCompleted) gate.complete();
          },
        );
      }, maxBytes: 2 * mib);
      try {
        final first = await reader
            .read('', 0, mib, DiscReadCancellation(), availableOnly: true)
            .timeout(const Duration(seconds: 1));
        expect(first.bytes.length, chunk);
        expect(first.bytes.every((v) => v == 19), true);
        expect(gate.isCompleted, false);
        gate.complete();
        final next = await reader.read(
          '',
          chunk,
          mib,
          DiscReadCancellation(),
          availableOnly: true,
        );
        expect(next.bytes.length, chunk);
        expect(next.bytes.every((v) => v == 23), true);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await reader.close();
      }
    },
  );
  test(
    'producer continues during consumer idle and stops at its byte budget',
    () async {
      final source = Source();
      final reader = DiscOrderedReader(source.open, maxBytes: 2 * mib);
      addTearDown(reader.close);
      await reader.read('', 0, mib, DiscReadCancellation());
      await until(() => reader.retainedBytes == 2 * mib);
      expect(source.received, 3 * mib);
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(source.received, 3 * mib);
      expect(source.opens, 1);
      expect(reader.peakBytes, lessThanOrEqualTo(2 * mib));
      final next = await reader.read('', mib, mib, DiscReadCancellation());
      expect(next.bytes[0], 16);
      await until(() => source.received == 4 * mib);
      expect(source.opens, 1);
    },
  );

  test(
    'a small demand does not start whole-file speculative download',
    () async {
      final source = Source();
      final reader = DiscOrderedReader(source.open, maxBytes: 2 * mib);
      addTearDown(reader.close);
      await reader.read('', 0, chunk, DiscReadCancellation());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(source.received, chunk);
    },
  );

  test('successive requests preserve byte offsets and one response', () async {
    final source = Source();
    final reader = DiscOrderedReader(source.open, maxBytes: 2 * mib);
    addTearDown(reader.close);
    for (var at = 0; at < 8 * mib; at += mib) {
      final block = await reader.read('', at, mib, DiscReadCancellation());
      for (var offset = 0; offset < mib; offset += chunk) {
        expect(block.bytes[offset], (at + offset) ~/ chunk % 251);
      }
    }
    expect(source.opens, 1);
    expect(source.peak, 1);
  });

  test('already-ready forward jump reuses the continuous response', () async {
    final source = Source();
    final reader = DiscOrderedReader(source.open, maxBytes: 4 * mib);
    addTearDown(reader.close);
    await reader.read('', 0, mib, DiscReadCancellation());
    await until(() => reader.retainedBytes == 4 * mib);
    final block = await reader.read('', 3 * mib, mib, DiscReadCancellation());
    expect(block.bytes[0], 48);
    expect(source.opens, 1);
  });

  test(
    'distant seek retires a full old queue before opening another response',
    () async {
      final source = Source();
      final reader = DiscOrderedReader(source.open, maxBytes: 2 * mib);
      addTearDown(reader.close);
      await reader.read('', 0, mib, DiscReadCancellation());
      await until(() => reader.retainedBytes == 2 * mib);
      final block = await reader.read('', 9 * mib, mib, DiscReadCancellation());
      expect(block.bytes[0], 144);
      expect(source.starts, [0, 9 * mib]);
      expect(source.peak, 1);
    },
  );

  test('backward seek cannot return stale forward data', () async {
    final source = Source();
    final reader = DiscOrderedReader(source.open, maxBytes: mib);
    addTearDown(reader.close);
    await reader.read('', 4 * mib, mib, DiscReadCancellation());
    final block = await reader.read('', 0, mib, DiscReadCancellation());
    expect(block.bytes[0], 0);
    expect(source.starts, [4 * mib, 0]);
    expect(source.peak, 1);
  });

  test('file change cannot reuse bytes from the old file', () async {
    final source = Source();
    final reader = DiscOrderedReader(source.open, maxBytes: mib);
    addTearDown(reader.close);
    await reader.read('a', 0, mib, DiscReadCancellation());
    await reader.read('b', mib, mib, DiscReadCancellation());
    expect(source.opens, 2);
    expect(source.peak, 1);
  });

  test('close wakes a producer blocked on a full queue', () async {
    final source = Source();
    final reader = DiscOrderedReader(source.open, maxBytes: mib);
    await reader.read('', 0, mib, DiscReadCancellation());
    await until(() => reader.retainedBytes == mib);
    await reader.close().timeout(const Duration(seconds: 1));
    expect(source.active, 0);
    expect(reader.retainedBytes, 0);
    await reader.close();
  });

  test(
    'close cancels an in-flight source read and wakes its consumer',
    () async {
      final source = Source()..gate = Completer<void>();
      final reader = DiscOrderedReader(source.open, maxBytes: mib);
      final pending = reader.read('', 0, mib, DiscReadCancellation());
      final failed = expectLater(pending, throwsA(anything));
      await until(() => source.opens == 1);
      await reader.close().timeout(const Duration(seconds: 1));
      await failed;
      expect(source.active, 0);
    },
  );

  test('cancelled request does not poison the next position', () async {
    final source = Source()..gate = Completer<void>();
    final reader = DiscOrderedReader(source.open, maxBytes: mib);
    addTearDown(reader.close);
    final token = DiscReadCancellation();
    final failed = expectLater(
      reader.read('', 0, mib, token),
      throwsA(anything),
    );
    await until(() => source.opens == 1);
    token.cancel();
    await failed;
    source.gate = null;
    final next = await reader.read('', 8 * mib, mib, DiscReadCancellation());
    expect(next.bytes[0], 128);
    expect(source.peak, 1);
  });

  test(
    'real producer failure remains visible and is not retried indefinitely',
    () async {
      final source = Source()..failAt = 2 * mib;
      final reader = DiscOrderedReader(source.open, maxBytes: mib);
      addTearDown(reader.close);
      await reader.read('', 0, mib, DiscReadCancellation());
      await expectLater(
        reader.read('', mib, 2 * mib, DiscReadCancellation()),
        throwsStateError,
      );
      await expectLater(
        reader.read('', 0, mib, DiscReadCancellation()),
        throwsStateError,
      );
      expect(source.opens, 1);
    },
  );

  test('last partial chunk preserves the exact file end', () async {
    final source = Source()..total = chunk + 173;
    final reader = DiscOrderedReader(source.open, maxBytes: mib);
    addTearDown(reader.close);
    final block = await reader.read('', 0, mib, DiscReadCancellation());
    expect(block.total, chunk + 173);
    expect(block.bytes.length, chunk + 173);
    expect(block.bytes[chunk], 1);
    expect(source.active, 0);
  });

  test('published prefixes stay unchanged while the tail arrives', () async {
    final source = Source();
    final reader = DiscOrderedReader(source.open, maxBytes: mib);
    addTearDown(reader.close);
    Uint8List? first;
    final block = await reader.read(
      '',
      0,
      mib,
      DiscReadCancellation(),
      onProgress: (part) {
        first ??= part.bytes;
      },
    );
    expect(first!.length, chunk);
    expect(first, block.bytes.sublist(0, chunk));
    await reader.read('', mib, mib, DiscReadCancellation());
    expect(first, block.bytes.sublist(0, chunk));
  });
}
