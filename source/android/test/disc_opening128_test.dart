import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_ordered_reader.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'disc_speed_reader_test.dart' show SourceFixture, mib;
import 'host/opening128/current.dart' as current;

void main() {
  test(
    'healthy first disc play keeps its continuous response and does not fabricate starvation',
    () async {
      final fixture = SourceFixture(total: 20 * mib);
      final reader = DiscOrderedReader(
        fixture.single,
        openPart: fixture.part,
        maxBytes: 12 * mib,
      );
      final h = current.Harness()..forward = reader.setBuffering;
      try {
        await reader.read('', 0, 65536, DiscReadCancellation());
        await h.play();
        for (var at = 65536; at < 10 * mib; at += 65536) {
          final b = await reader.read('', at, 65536, DiscReadCancellation());
          expect(b.bytes.first, (at ~/ (256 * 1024)) % 251);
        }
        expect(h.hints.where((v) => v), isEmpty);
        expect(fixture.opened.where((r) => r.part), isEmpty);
        expect(fixture.peak, 1);
      } finally {
        await reader.close();
      }
    },
  );
}
