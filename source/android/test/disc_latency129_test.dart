// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'package:yingyu/playback/disc_ordered_reader.dart';
import 'disc_speed_reader_test.dart' show SourceFixture, mib;
import 'host/opening128/current.dart' as current;
import 'host/disc129/old_startup.dart' as baseline;
import 'host/disc129/old_ordered.dart' as old;
import 'package:yingyu/playback/disc_startup.dart';

void main() {
  test(
    'first play with native two-second gate must not add a second four-second wait',
    () async {
      final h = current.Harness();
      h.native.values['demuxer-cache-duration'] = '3.424000';
      h.native.values['cache-pause-wait'] = '2.000000';
      h.native.values['seeking'] = 'no';
      h.native.values['paused-for-cache'] = 'no';
      final clock = Stopwatch()..start();
      await h.play();
      print(
        '129 first-play native gate already met: ${clock.elapsedMilliseconds}ms',
      );
      expect(h.player.playCalls, 1);
      expect(
        clock.elapsedMilliseconds,
        lessThan(250),
        reason: '3.42 seconds already exceeds the real native resume gate',
      );
    },
  );
  for (final legacy in [false, true]) {
    test(
      'one-speed starvation legacy=$legacy must not discard a live response for slow range handshakes',
      () async {
        final fixture = SourceFixture(
          total: 40 * mib,
          delay: const Duration(milliseconds: 1),
        );
        Future<DiscStreamSource> part(
          String path,
          int start,
          int end,
          DiscStreamIdentity id,
          DiscReadCancellation token,
        ) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return fixture.part(path, start, end, id, token);
        }

        final dynamic reader = legacy
            ? old.DiscOrderedReader(
                fixture.single,
                maxBytes: 12 * mib,
                openPart: part,
              )
            : DiscOrderedReader(
                fixture.single,
                maxBytes: 12 * mib,
                openPart: part,
              );
        try {
          for (var at = 0; at < 8 * mib; at += 65536) {
            await reader.read('', at, 65536, DiscReadCancellation());
          }
          final clock = Stopwatch()..start();
          reader.setBuffering(true);
          for (var at = 8 * mib; at < 40 * mib; at += 65536) {
            final DiscRangeBlock b = await reader.read(
              '',
              at,
              65536,
              DiscReadCancellation(),
            );
            expect(b.bytes.first, (at ~/ (256 * 1024)) % 251);
          }
          print(
            '129 one-speed stalled supply legacy=$legacy: range handshakes=${fixture.partNumber}, elapsed=${clock.elapsedMilliseconds}ms',
          );
          expect(
            fixture.partNumber > 0,
            legacy,
            reason:
                'only the old one-speed path launches slow extra handshakes',
          );
          expect(fixture.peak, legacy ? lessThanOrEqualTo(2) : 1);
        } finally {
          await reader.close();
        }
      },
    );
  }
  test(
    'complete128 baseline wastes the three-second budget above its native gate',
    () async {
      final clock = Stopwatch()..start();
      await baseline.waitForDiscCushion(
        read: (key) async =>
            {
              'demuxer-cache-duration': '3.424000',
              'demuxer-cache-idle': 'no',
              'eof-reached': 'no',
              'cache-pause-wait': '2.000000',
            }[key] ??
            '',
        active: () => true,
      );
      print('128 baseline extra cold wait: ${clock.elapsedMilliseconds}ms');
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(2900));
    },
  );
  for (final gate in ['2', '4', '24', '', 'NaN', '-2', '999']) {
    test(
      'native gate is bounded and unknown gates keep conservative behavior: $gate',
      () async {
        final result = await waitForDiscCushion(
          read: (key) async =>
              {
                'demuxer-cache-duration': '3.424',
                'demuxer-cache-idle': 'no',
                'eof-reached': 'no',
                'cache-pause-wait': gate,
              }[key] ??
              '',
          active: () => true,
          timeout: const Duration(milliseconds: 60),
        );
        expect(result.contains('已达到'), gate == '2');
      },
    );
  }
  for (final exit in ['idle', 'eof', 'cancel', 'unknown', 'invalidDuration']) {
    test(
      'native full/EOF/cancel and invalid duration remain real: $exit',
      () async {
        final active = exit != 'cancel';
        final result = await waitForDiscCushion(
          read: (key) async {
            if (exit == 'unknown') throw StateError('unavailable');
            return {
                  'demuxer-cache-duration': exit == 'invalidDuration'
                      ? 'NaN'
                      : '0',
                  'demuxer-cache-idle': exit == 'idle' ? 'yes' : 'no',
                  'eof-reached': exit == 'eof' ? 'yes' : 'no',
                  'cache-pause-wait': '2',
                }[key] ??
                '';
          },
          active: () => active,
          timeout: const Duration(milliseconds: 60),
        );
        expect(
          result,
          contains(
            exit == 'cancel'
                ? '已取消'
                : exit == 'idle' || exit == 'eof'
                ? '缓存已满'
                : exit == 'unknown'
                ? '暂不可确认'
                : '有界等待结束',
          ),
        );
      },
    );
  }
}
