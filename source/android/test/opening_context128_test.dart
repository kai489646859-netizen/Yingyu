import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/tracks.dart';
import 'opening_subtitle128_test.dart' show values;
import 'host/opening128/subtitles.dart';

void main() {
  test(
    'a delayed preload for a different path cannot select its old subtitle',
    () async {
      final io = NativePlayer()..values.addAll(values()..['path'] = 'other');
      final h = HookHarness()
        ..expectedAddress = 'synthetic'
        ..choose = preferredSubtitle;
      await h.prepare(io, const Duration(seconds: 20));
      expect(io.writes, isEmpty);
    },
  );
  test(
    'media changing during parsed-track reads cannot publish a subtitle choice',
    () async {
      final io = NativePlayer()
        ..values.addAll(values()..['path'] = 'synthetic');
      io.onRead = (key) {
        if (key == 'track-list/count') {
          io.values['path'] = 'next';
        }
      };
      final h = HookHarness()
        ..expectedAddress = 'synthetic'
        ..choose = preferredSubtitle;
      await h.prepare(io, const Duration(seconds: 20));
      expect(io.writes, isEmpty);
    },
  );
}
