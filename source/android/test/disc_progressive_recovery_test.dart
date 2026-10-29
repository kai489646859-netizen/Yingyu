import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_speed_reader.dart';
import 'package:yingyu/playback/disc_stream.dart';

const _mib = 1024 * 1024;

void main() {
  for (final outcome in ['same', 'changed', 'interrupted-again']) {
    test(
      'already delivered prefix survives bounded recovery: $outcome',
      () async {
        const total = 64 * _mib, target = 12 * _mib;
        const identity = DiscStreamIdentity('synthetic', 'v1', total);
        final cut = Completer<void>();
        final opens = <int>[];
        var boundedCut = false;
        Uint8List bytes(int at, int count) =>
            Uint8List(count)..fillRange(0, count, at ~/ _mib);
        Stream<List<int>> body(
          int start,
          int end, {
          bool interrupted = false,
        }) async* {
          for (var at = start; at < end; at += _mib) {
            if (interrupted && at == target + _mib) {
              await cut.future;
              throw const SocketException('synthetic interruption');
            }
            yield bytes(at, (end - at).clamp(0, _mib));
          }
        }

        final reader = DiscSpeedReader(
          (path, start, cancel) async {
            opens.add(start);
            return DiscStreamSource(
              start: start,
              total: total,
              identity: start == target && outcome == 'changed'
                  ? const DiscStreamIdentity('synthetic', 'v2', total)
                  : identity,
              validator: 'v1',
              canResume: true,
              bytes: body(
                start,
                total,
                interrupted: start == target && outcome == 'interrupted-again',
              ),
              close: (_) {},
            );
          },
          (path, start, end, expected, cancel) async {
            if (start == target) boundedCut = true;
            return DiscStreamSource(
              start: start,
              total: total,
              identity: identity,
              bytes: body(start, end + 1, interrupted: start == target),
              close: (_) {},
            );
          },
          partBytes: 32 * _mib,
        )..setSpeed(3);
        final cache = DiscRangeCache(
          reader.read,
          progressiveFetch: (p, s, n, c, progress) =>
              reader.read(p, s, n, c, onProgress: progress),
        )..setSpeed(3);
        try {
          for (var at = 0; at <= target; at += _mib) {
            final block = await cache.read('', at, _mib);
            expect(block.bytes.length, _mib);
            expect(block.bytes.every((v) => v == at ~/ _mib), isTrue);
          }
          expect(boundedCut, isTrue);
          expect(cut.isCompleted, isFalse);
          final next = cache.read('', target + _mib, _mib);
          if (outcome == 'same') {
            cut.complete();
            for (var at = target + _mib; at < target + 4 * _mib; at += _mib) {
              final block = at == target + _mib
                  ? await next
                  : await cache.read('', at, _mib);
              expect(block.bytes.length, _mib);
              expect(block.bytes.every((v) => v == at ~/ _mib), isTrue);
            }
          } else {
            final failure = outcome == 'changed'
                ? isA<DiscIdentityFailure>()
                : isA<SocketException>();
            final failed = expectLater(next, throwsA(failure));
            cut.complete();
            await failed;
            await expectLater(
              cache.read('', target + _mib, _mib),
              throwsA(failure),
            );
          }
          expect(opens, [
            0,
            target,
          ], reason: 'Recovery is once only, and refills the same block.');
          expect(reader.peakResponses, lessThanOrEqualTo(2));
          expect(reader.peakPartBytes, lessThanOrEqualTo(64 * _mib));
        } finally {
          if (!cut.isCompleted) cut.complete();
          cache.close();
          await reader.close();
        }
      },
    );
  }
}
