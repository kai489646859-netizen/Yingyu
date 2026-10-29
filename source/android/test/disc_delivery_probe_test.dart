import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_speed_reader.dart';
import 'package:yingyu/playback/disc_stream.dart';

const _mib = 1024 * 1024;

// Controlled producer/consumer probe, not native decoding or a line speed test.
// The qualified cases have sufficient aggregate source capacity; an earlier response must not
// force the faster later response to sit on a full out-of-order buffer.
class _Lanes {
  _Lanes(this.slow, this.fast);
  final double slow, fast;
  final busy = [false, false];
  final identity = const DiscStreamIdentity('synthetic', '"one"', 2048 * _mib);
  final bytes = Uint8List(_mib);
  int requests = 0, peak = 0;

  Future<DiscStreamSource> single(
    String path,
    int start,
    DiscReadCancellation cancel,
  ) async => _source(start, identity.total, null, cancel);

  Future<DiscStreamSource> part(
    String path,
    int start,
    int end,
    DiscStreamIdentity expected,
    DiscReadCancellation cancel,
  ) async {
    final lane = busy.indexOf(false);
    if (lane < 0) throw StateError("third synthetic lane");
    busy[lane] = true;
    requests++;
    final active = busy.where((v) => v).length;
    if (active > peak) peak = active;
    return _source(start, end + 1, lane, cancel);
  }

  DiscStreamSource _source(
    int start,
    int end,
    int? lane,
    DiscReadCancellation cancel,
  ) {
    var closed = false;
    final stream = StreamController<List<int>>();
    Timer? timer, header;
    var at = start;
    void close(bool _) {
      if (closed) return;
      closed = true;
      timer?.cancel();
      header?.cancel();
      unawaited(stream.close());
      if (lane != null) busy[lane] = false;
    }

    // Keep-alive requests still incur a response delay. The producer honors
    // socket backpressure instead of queuing unlimited test data in memory.
    header = Timer(const Duration(milliseconds: 150), () {
      timer = Timer.periodic(
        Duration(
          microseconds:
              (1000000 /
                      (lane == null
                          ? 64
                          : lane == 0
                          ? slow
                          : fast))
                  .round(),
        ),
        (_) {
          if (closed || stream.isPaused) return;
          if (at >= end) {
            timer?.cancel();
            unawaited(stream.close());
            return;
          }
          stream.add(bytes);
          at += bytes.length;
          if (at >= end) {
            timer?.cancel();
            unawaited(stream.close());
          }
        },
      );
    });

    return DiscStreamSource(
      start: start,
      total: identity.total,
      bytes: stream.stream,
      identity: identity,
      close: close,
    );
  }
}

void main() {
  final cases = [
    for (final budget in [16, 32])
      for (final slow in [2.0, 4.0])
        (budget: budget, slow: slow, fast: 30.0, sufficient: true),
    (budget: 32, slow: 16.0, fast: 16.0, sufficient: true),
    (budget: 32, slow: 2.0, fast: 2.0, sufficient: false),
  ];
  for (final scenario in cases) {
    for (final rate in [2.0, 3.0]) {
      testWidgets('producer cadence $rate x / ${scenario.budget} MiB lane budget / '
          '${scenario.slow}+${scenario.fast} MiB per second', (tester) async {
        final lanes = _Lanes(scenario.slow, scenario.fast);
        final reader = DiscSpeedReader(
          lanes.single,
          lanes.part,
          partBytes: scenario.budget * _mib,
        )..setSpeed(rate);
        var offset = 0, buffered = 0.0, starvedSeconds = 0.0;
        var stopped = false, playing = false, pending = false;
        Object? failure;
        void fetch() {
          if (stopped || pending || buffered > 96 * _mib) return;
          pending = true;
          reader
              .read('', offset, 4 * _mib, DiscReadCancellation())
              .then(
                (block) {
                  buffered += block.bytes.length;
                  offset += block.bytes.length;
                  pending = false;
                  fetch();
                },
                onError: (Object error) {
                  if (!stopped) failure = error;
                  pending = false;
                },
              );
        }

        fetch();
        // Explicit virtual playback model: 48 MiB start, 96 MiB forward window,
        // a 60 second run and the provided clip's average bytes per media second.
        // It is neither a native MPV simulation nor a device stutter reproduction.
        for (var step = 0; step < 6000; step++) {
          await tester.pump(const Duration(milliseconds: 10));
          // StreamIterator.cancel may complete in the root zone. Let those
          // retirements settle without advancing virtual network time.
          await tester.runAsync(() async {});
          expect(failure, isNull);
          if (!playing && buffered >= 48 * _mib) playing = true;
          if (playing) {
            final consumed = 5.117329388 * rate * _mib * .01;
            if (buffered < consumed) {
              starvedSeconds += (consumed - buffered) / consumed * .01;
            }
            buffered = (buffered - consumed).clamp(0, double.infinity);
          }
          fetch();
        }
        stopped = true;
        var closed = false;
        reader.close().then((_) => closed = true);
        for (var step = 0; step < 20 && !closed; step++) {
          await tester.runAsync(() async {});
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(closed, isTrue);
        expect(reader.peakResponses, lessThanOrEqualTo(2));
        expect(
          reader.peakPartBytes,
          lessThanOrEqualTo(2 * scenario.budget * _mib),
        );
        expect(lanes.requests, greaterThan(0));
        // A deliberately underfed source must still expose starvation. The
        // policy must not hide it, slow the selected rate or grow the budget.
        // ignore: avoid_print
        print(
          'CADENCE rate=$rate budget=${scenario.budget} '
          'lanes=${scenario.slow}+${scenario.fast} sufficient=${scenario.sufficient} '
          'starvation=$starvedSeconds requests=${lanes.requests} deliveredMiB=${offset / _mib}',
        );
        expect(playing, isTrue);
        expect(starvedSeconds, scenario.sufficient ? 0 : greaterThan(0));
      });
    }
  }
}
