import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/opening_surface.dart';
import 'opening_surface127_test.dart' show header;

void main() {
  test(
    'zero rotation unavailable uses the real native empty-string getter',
    () async {
      final values = header()..['track-list/0/demux-rotation'] = '';
      final prepared = <List<int>>[];
      final result = await prepareOpenedVideoSurface(
        address: 'synthetic',
        read: (key) async => values[key] ?? '',
        prepare: (w, h) async {
          prepared.add([w, h]);
          return true;
        },
        active: () => true,
      );
      expect(result, true);
      expect(prepared, [
        [3840, 2160],
      ]);
    },
  );
}
