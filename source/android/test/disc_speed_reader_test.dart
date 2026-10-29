import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'package:yingyu/playback/disc_speed_reader.dart';

const mib = 1024 * 1024;

class SourceFixture {
  SourceFixture({
    this.qualified = true,
    this.delay = Duration.zero,
    this.failPart,
    this.changedPart,
    this.total = 64 * mib + 57,
    this.sharedLimit = false,
    this.cutPart,
    this.cutRecovery = false,
  });
  final bool qualified;
  final bool sharedLimit;
  final int? cutPart;
  final bool cutRecovery;
  final _senders = <void Function()>[];
  Timer? _sharedTimer;
  int _turn = 0;
  final Duration delay;
  final int? failPart, changedPart;
  final int total;
  final opened = <({int start, int end, bool part})>[];
  int active = 0, peak = 0, partNumber = 0;
  DiscStreamIdentity get identity =>
      DiscStreamIdentity('http://external.invalid/a', '"v1"', total);

  Future<DiscStreamSource> single(
    String path,
    int start,
    DiscReadCancellation c,
  ) => source(start, total - 1, c, part: false);
  Future<DiscStreamSource> part(
    String path,
    int start,
    int end,
    DiscStreamIdentity expected,
    DiscReadCancellation c,
  ) => source(start, end, c, part: true);

  Future<DiscStreamSource> source(
    int start,
    int end,
    DiscReadCancellation c, {
    required bool part,
  }) async {
    c.check();
    opened.add((start: start, end: end, part: part));
    final number = part ? ++partNumber : 0;
    final truncated =
        number == cutPart ||
        cutRecovery && !part && opened.where((r) => !r.part).length > 1;
    if (number == failPart) {
      throw const AppFailure('synthetic secondary failed');
    }
    active++;
    if (active > peak) peak = active;
    var closed = false;
    final stream = StreamController<List<int>>();
    Timer? timer;
    var at = start;
    void send() {
      if (closed || stream.isPaused) return;
      if (at > end || truncated && at >= start + 2 * mib) {
        unawaited(stream.close());
        timer?.cancel();
        return;
      }
      final length = (end - at + 1).clamp(0, 256 * 1024);
      final bytes = Uint8List(length);
      for (var i = 0; i < length;) {
        final count = (256 * 1024 - (at + i) % (256 * 1024)).clamp(
          0,
          length - i,
        );
        bytes.fillRange(i, i + count, ((at + i) ~/ (256 * 1024)) % 251);
        i += count;
      }
      stream.add(bytes);
      at += length;
    }

    if (sharedLimit) {
      _senders.add(send);
      _sharedTimer ??= Timer.periodic(delay, (_) {
        if (_senders.isNotEmpty) _senders[_turn++ % _senders.length]();
      });
    } else {
      timer = Timer.periodic(
        delay == Duration.zero ? const Duration(microseconds: 1) : delay,
        (_) => send(),
      );
    }
    if (delay == Duration.zero) stream.onResume = send;
    return DiscStreamSource(
      start: start,
      total: total,
      bytes: stream.stream,
      canResume: qualified,
      identity: !qualified
          ? null
          : number == changedPart
          ? DiscStreamIdentity(identity.address, '"v2"', total)
          : identity,
      close: (_) {
        if (closed) return;
        closed = true;
        active--;
        timer?.cancel();
        _senders.remove(send);
        if (_senders.isEmpty) {
          _sharedTimer?.cancel();
          _sharedTimer = null;
        }
        unawaited(stream.close());
      },
    );
  }
}

Future<void> checkBytes(DiscSpeedReader reader, int start, int length) async {
  final block = await reader.read('', start, length, DiscReadCancellation());
  expect(block.start, start);
  expect(block.bytes.length, length);
  for (var at = 0; at < length; at += 256 * 1024) {
    expect(block.bytes[at], ((start + at) ~/ (256 * 1024)) % 251);
  }
  expect(block.bytes.last, ((start + length - 1) ~/ (256 * 1024)) % 251);
}

void main() {
  for (final secondFailure in [false, true]) {
    test(
      'bounded body interruption shares one recovery budget, secondFailure=$secondFailure',
      () async {
        final fixture = SourceFixture(
          cutPart: 2,
          cutRecovery: secondFailure,
          delay: const Duration(milliseconds: 1),
        );
        final reader = DiscSpeedReader(
          fixture.single,
          fixture.part,
          partBytes: 4 * mib,
        )..setSpeed(3);
        try {
          var failed = false;
          try {
            for (var at = 0; at < 64 * mib; at += 4 * mib) {
              await checkBytes(reader, at, 4 * mib);
            }
          } on AppFailure {
            failed = true;
          }
          expect(failed, secondFailure);
          expect(
            fixture.opened.where((r) => !r.part).length,
            2,
            reason: 'one original continuous source and at most one recovery',
          );
          expect(fixture.peak, lessThanOrEqualTo(2));
          expect(reader.mode, contains('退回'));
        } finally {
          await reader.close();
        }
      },
    );
  }
  for (final shared in [false, true]) {
    test(
      'one trial keeps useful parallelism and retires no-gain sharedLimit=$shared',
      () async {
        final messages = <String>[];
        final fixture = SourceFixture(
          sharedLimit: shared,
          delay: const Duration(milliseconds: 10),
        );
        final reader = DiscSpeedReader(
          fixture.single,
          fixture.part,
          partBytes: 4 * mib,
          onDiagnostic: messages.add,
        );
        try {
          await checkBytes(reader, 0, 4 * mib);
          await checkBytes(reader, 4 * mib, 4 * mib);
          reader.setSpeed(3);
          for (var at = 8 * mib; at < 64 * mib; at += 4 * mib) {
            await checkBytes(reader, at, 4 * mib);
          }
          expect(messages.any((m) => m.contains('1.1 倍')), shared);
          expect(fixture.peak, 2);
          if (shared) {
            expect(reader.retainedBytes, 0);
            final count = fixture.partNumber;
            reader.setSpeed(1);
            reader.setSpeed(3);
            await checkBytes(reader, 64 * mib, 57);
            expect(fixture.partNumber, count);
          }
        } finally {
          await reader.close();
        }
      },
    );
  }

  test(
    'failure after bounded handoff does not open a further range or retry',
    () async {
      final fixture = SourceFixture(failPart: 2);
      final reader = DiscSpeedReader(
        fixture.single,
        fixture.part,
        partBytes: 4 * mib,
      )..setSpeed(3);
      try {
        var failed = false;
        try {
          for (var at = 0; at < 32 * mib; at += 4 * mib) {
            await checkBytes(reader, at, 4 * mib);
          }
        } on AppFailure {
          failed = true;
        }
        expect(failed, true);
        expect(fixture.partNumber, 2);
        final count = fixture.opened.length;
        await expectLater(
          checkBytes(reader, 24 * mib, 4 * mib),
          throwsA(isA<AppFailure>()),
        );
        expect(fixture.opened.length, count);
      } finally {
        await reader.close();
      }
    },
  );
  for (final qualified in [false, true]) {
    test(
      '3x exact bytes with qualification=$qualified, bounded RAM and <=2 responses',
      () async {
        final fixture = SourceFixture(qualified: qualified);
        final reader = DiscSpeedReader(
          fixture.single,
          fixture.part,
          partBytes: 4 * mib,
        )..setSpeed(3);
        try {
          for (var at = 0; at < 64 * mib; at += 4 * mib) {
            await checkBytes(reader, at, 4 * mib);
          }
          await checkBytes(reader, 64 * mib, 57);
          expect(fixture.peak, qualified ? 2 : 1);
          expect(reader.peakPartBytes, lessThanOrEqualTo(8 * mib));
          if (!qualified) expect(fixture.opened.length, 1);
        } finally {
          await reader.close();
        }
        expect(fixture.active, 0);
      },
    );
  }
  for (final speed in [1.0, 1.25]) {
    test(
      'lowering 3x to $speed drains warmed data then returns to one response',
      () async {
        final fixture = SourceFixture();
        final reader = DiscSpeedReader(
          fixture.single,
          fixture.part,
          partBytes: 4 * mib,
        )..setSpeed(3);
        try {
          await checkBytes(reader, 0, 4 * mib);
          await checkBytes(reader, 4 * mib, 4 * mib);
          reader.setSpeed(speed);
          final count = fixture.opened.length;
          for (var at = 8 * mib; at < 64 * mib; at += 4 * mib) {
            await checkBytes(reader, at, 4 * mib);
          }
          expect(fixture.opened.where((x) => x.part).length, 1);
          expect(fixture.opened.length, count + 1);
          expect(fixture.peak, 2);
          expect(reader.retainedBytes, 0);
        } finally {
          await reader.close();
        }
      },
    );
  }
  test(
    'failed optional range preserves unbounded primary and does not try again',
    () async {
      final fixture = SourceFixture(failPart: 1);
      final reader = DiscSpeedReader(
        fixture.single,
        fixture.part,
        partBytes: 4 * mib,
      )..setSpeed(3);
      try {
        for (var at = 0; at < 64 * mib; at += 4 * mib) {
          await checkBytes(reader, at, 4 * mib);
        }
        expect(fixture.opened.length, 2);
        expect(reader.mode, contains('退回'));
      } finally {
        await reader.close();
      }
    },
  );
  test(
    'changed identity is terminal and no new range is requested on repeated reads',
    () async {
      final fixture = SourceFixture(changedPart: 1);
      final reader = DiscSpeedReader(
        fixture.single,
        fixture.part,
        partBytes: 4 * mib,
      )..setSpeed(3);
      try {
        await checkBytes(reader, 0, 4 * mib);
        await checkBytes(reader, 4 * mib, 4 * mib);
        await expectLater(
          checkBytes(reader, 8 * mib, 4 * mib),
          throwsA(isA<DiscIdentityFailure>()),
        );
        final opens = fixture.opened.length;
        await expectLater(
          checkBytes(reader, 8 * mib, 4 * mib),
          throwsA(isA<DiscIdentityFailure>()),
        );
        expect(fixture.opened.length, opens);
        expect(fixture.active, 0);
      } finally {
        await reader.close();
      }
    },
  );
  test(
    'seek retires both old responses before any replacement and keeps byte identity',
    () async {
      final fixture = SourceFixture(delay: const Duration(milliseconds: 1));
      final reader = DiscSpeedReader(
        fixture.single,
        fixture.part,
        partBytes: 4 * mib,
      )..setSpeed(3);
      try {
        for (var at = 0; at < 12 * mib; at += 4 * mib) {
          await checkBytes(reader, at, 4 * mib);
        }
        await checkBytes(reader, 48 * mib, 4 * mib);
        await checkBytes(reader, 52 * mib, 4 * mib);
        await checkBytes(reader, 0, 4 * mib);
        expect(fixture.peak, lessThanOrEqualTo(2));
      } finally {
        await reader.close();
      }
      expect(fixture.active, 0);
    },
  );
  test(
    'closing while a requested part is in flight completes all waiters',
    () async {
      final fixture = SourceFixture(delay: const Duration(milliseconds: 2));
      final reader = DiscSpeedReader(
        fixture.single,
        fixture.part,
        partBytes: 4 * mib,
      )..setSpeed(3);
      await checkBytes(reader, 0, 4 * mib);
      await checkBytes(reader, 4 * mib, 4 * mib);
      final c = DiscReadCancellation();
      final pending = reader.read('', 8 * mib, 4 * mib, c);
      final assertion = expectLater(pending, throwsA(isA<AppFailure>()));
      await reader.close().timeout(const Duration(seconds: 2));
      await assertion;
      expect(fixture.active, 0);
    },
  );
}
