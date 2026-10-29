import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/src/player/native/utils/letterbox.dart';
import 'package:yingyu/playback/phone_fit.dart';
import 'package:yingyu/playback/player_status.dart';

Uint8List frame({
  int width = 640,
  int height = 360,
  int top = 48,
  int bottom = 48,
  bool dark = false,
  int padding = 0,
}) {
  final stride = width * 4 + padding;
  final bytes = Uint8List(stride * height);
  if (!dark) {
    for (var y = top; y < height - bottom; y++) {
      for (var x = 0; x < width; x++) {
        final p = y * stride + x * 4;
        bytes[p] = 70;
        bytes[p + 1] = 110;
        bytes[p + 2] = 160;
      }
    }
  }
  return bytes;
}

class FitFixture {
  final options = <String, String>{
    'panscan': '0',
    'video-crop': '',
    'stretch-image-subs-to-screen': 'no',
  };
  final writes = <String>[];
  final messages = <String>[];
  List<int>? sample = [640, 360, 44];
  Completer<List<int>?>? gate;
  bool healthy = true;
  int probes = 0;
  late final fit = PhoneFit(
    read: (key) async => options[key]!,
    write: (key, value) async {
      options[key] = value;
      writes.add('$key=$value');
    },
    detect: () async {
      probes++;
      return gate == null ? sample : gate!.future;
    },
    healthy: () => healthy,
    record: messages.add,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'symmetric bands keep four-pixel picture safety edge and explicit stride',
    () {
      expect(letterboxBounds(frame(), 640, 360, 2560), [640, 360, 44]);
      expect(letterboxBounds(frame(padding: 32), 640, 360, 2592), [
        640,
        360,
        44,
      ]);
    },
  );
  test(
    'full frame, asymmetric borders, dark scenes and invalid buffers are not cropped',
    () {
      expect(letterboxBounds(frame(top: 0, bottom: 0), 640, 360, 2560), [
        640,
        360,
        0,
      ]);
      expect(letterboxBounds(frame(top: 30, bottom: 48), 640, 360, 2560), [
        640,
        360,
        0,
      ]);
      expect(letterboxBounds(frame(dark: true), 640, 360, 2560), isNull);
      expect(letterboxBounds(Uint8List(8), 640, 360, 2560), isNull);
      expect(letterboxBounds(frame(), 640, 360, 2500), isNull);
      expect(letterboxBounds(Uint8List(8), 7680, 4320, 30720), isNull);
    },
  );
  testWidgets(
    'adaptation requires three stable healthy frames and restores variable aspect',
    (tester) async {
      final f = FitFixture();
      await f.fit.configure(fill: false);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));
      expect(f.options['video-crop'], '');
      await tester.pump(const Duration(seconds: 4));
      expect(f.options['panscan'], '1.000000');
      expect(f.options['stretch-image-subs-to-screen'], 'yes');
      f.sample = null; // A dark scene does not remove a valid crop.
      await tester.pump(const Duration(seconds: 15));
      expect(f.options['panscan'], '1.000000');
      f.sample = [640, 360, 0];
      await tester.pump(const Duration(seconds: 15));
      expect(f.options['panscan'], '0');
      f.fit.dispose();
    },
  );
  testWidgets(
    'normal movies stop optional detection and hidden or paused sessions do not sample',
    (tester) async {
      final f = FitFixture()..sample = [640, 360, 0];
      await f.fit.configure(fill: false);
      f.healthy = false;
      await tester.pump(const Duration(seconds: 4));
      expect(f.probes, 0);
      f.healthy = true;
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 4));
      }
      expect(f.probes, 3);
      expect(f.options['video-crop'], '');
      f.fit.dispose();
    },
  );
  testWidgets(
    'fill cancels pending adaptation and preserves native subtitle canvas',
    (tester) async {
      final f = FitFixture();
      await f.fit.configure(fill: false);
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));
      f.gate = Completer<List<int>?>();
      await tester.pump(const Duration(seconds: 4));
      final fill = f.fit.configure(fill: true);
      f.gate!.complete([640, 360, 44]);
      await tester.pump();
      await fill;
      expect(f.options['panscan'], '1');
      expect(f.options['video-crop'], '');
      expect(f.options['stretch-image-subs-to-screen'], 'yes');
      final probes = f.probes;
      await tester.pump(const Duration(seconds: 30));
      expect(f.probes, probes);
      await f.fit.restore();
      expect(f.options, {
        'panscan': '0',
        'video-crop': '',
        'stretch-image-subs-to-screen': 'no',
      });
      f.fit.dispose();
    },
  );
  testWidgets('disposed probe cannot change a later session', (tester) async {
    final f = FitFixture();
    await f.fit.configure(fill: false);
    f.gate = Completer<List<int>?>();
    await tester.pump(const Duration(seconds: 4));
    f.fit.dispose();
    final writes = f.writes.length;
    f.gate!.complete([640, 360, 44]);
    await tester.pump();
    expect(f.writes.length, writes);
  });
  testWidgets(
    'phone rate stays measured across hidden controls and stops off page',
    (tester) async {
      var samples = 0, resets = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlayerStatusController.channel,
        (call) async {
          if (call.method == 'reset') {
            resets++;
            return null;
          }
          samples++;
          return {'rxBytesPerSecond': 2048.0};
        },
      );
      final c = PlayerStatusController();
      c.setKeepRateWarm(true);
      c.setActive(true);
      await tester.pump();
      c.setActive(false);
      await tester.pump(const Duration(seconds: 1));
      expect(c.value.rateText, '2.0 KB/s');
      final before = samples;
      c.setActive(true);
      expect(c.value.rateText, '2.0 KB/s');
      await tester.pump();
      expect(samples, greaterThan(before));
      expect(resets, 0);
      c.dispose();
      await tester.pump();
      final stopped = samples;
      await tester.pump(const Duration(seconds: 5));
      expect(samples, stopped);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlayerStatusController.channel,
        null,
      );
    },
  );
}
