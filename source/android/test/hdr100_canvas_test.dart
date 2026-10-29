import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'host/hdr100_current_canvas.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('synthetic/screen-canvas');
  final sizes = <String>[];
  setUp(() {
    sizes.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      expect(call.method, 'VideoOutputManager.SetSurfaceSize');
      sizes.add('${call.arguments['width']}x${call.arguments['height']}');
      return null;
    });
  });
  tearDown(
    () =>
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );
  test(
    'portrait and landscape screen canvases can be configured before media without IO',
    () async {
      final c = CanvasHarness()..sized = false;
      expect(await c.setScreenViewport(2512, 3840), true);
      expect(c.canvas, (2512, 3840));
      expect(sizes, isEmpty);
      expect(c.writes, isEmpty);
      expect(await c.setScreenViewport(3840, 2512), true);
      expect(c.canvas, (3840, 2512));
    },
  );
  test(
    'live screen resize only updates dimensions, preserves VO and transport',
    () async {
      final c = CanvasHarness();
      expect(await c.setScreenViewport(3840, 2512), true);
      expect(sizes, ['3840x2512']);
      expect(c.writes, [('android-surface-size', '3840x2512')]);
      expect(c.rect.value!.width, 3840);
      expect(c.rect.value!.height, 2512);
      expect(await c.setScreenViewport(3840, 2512), true);
      expect(sizes.length, 1);
    },
  );
  test(
    'active HDR keeps its separate surface while fallback canvas dimensions track resize',
    () async {
      final c = CanvasHarness()..hdr = true;
      expect(await c.setScreenViewport(2512, 3840), true);
      expect(c.writes, isEmpty);
      expect(c.canvas, (2512, 3840));
      expect(c.rect.value!.height, 3840);
    },
  );
  test(
    'exit while Android resize is pending cannot write a late native dimension',
    () async {
      final gate = Completer<void>(), entered = Completer<void>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        entered.complete();
        await gate.future;
        return null;
      });
      final c = CanvasHarness();
      final pending = c.setScreenViewport(1280, 800);
      await entered.future;
      c.retire();
      gate.complete();
      expect(await pending, false);
      expect(c.writes, isEmpty);
      expect(c.rect.value!.width, 1920);
    },
  );
  test('failed resize restores prior canvas and propagates failure', () async {
    var calls = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      sizes.add('${call.arguments['width']}x${call.arguments['height']}');
      if (calls++ == 0) {
        throw PlatformException(code: 'synthetic-resize-failure');
      }
      return null;
    });
    final c = CanvasHarness();
    await expectLater(
      c.setScreenViewport(1280, 800),
      throwsA(isA<PlatformException>()),
    );
    expect(sizes, ['1280x800', '1920x1080']);
    expect(c.canvas, (1920, 1080));
    expect(c.rect.value!.width, 1920);
    expect(c.writes, [('android-surface-size', '1920x1080')]);
  });
  test('successive viewport changes serialize in caller order', () async {
    final gate = Completer<void>(), entered = Completer<void>();
    var calls = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      sizes.add('${call.arguments['width']}x${call.arguments['height']}');
      if (calls++ == 0) {
        entered.complete();
        await gate.future;
      }
      return null;
    });
    final c = CanvasHarness();
    final a = c.setScreenViewport(1280, 800);
    await entered.future;
    final b = c.setScreenViewport(800, 1280);
    await Future<void>.delayed(Duration.zero);
    expect(sizes, ['1280x800']);
    gate.complete();
    await a;
    await b;
    expect(sizes, ['1280x800', '800x1280']);
    expect(c.canvas, (800, 1280));
  });
}
