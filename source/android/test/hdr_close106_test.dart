import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/native_hdr.dart';
import 'host/hdr106_old_adapter.dart' as old;
import 'host/hdr106_current_close.dart' as current;
import 'host/hdr106_old_close.dart' as before;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yingyu/native_hdr');
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'probe'
          ? {'status': 'ready'}
          : call.method == 'watch'
          ? {
              'sdk': 37,
              'display': 0,
              'hdrTypes': [2],
            }
          : null,
    );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });
  test(
    'close reaches the native cancellation seam while HDR admission is pending',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var detached = false;
      Future<bool> write({
        required int token,
        required int width,
        required int height,
        required String transfer,
        required bool fill,
      }) async {
        if (token > 0) {
          entered.complete();
          await release.future;
        }
        return false;
      }

      Future<void> detach() async {
        detached = true;
        if (!release.isCompleted) release.complete();
      }

      final dynamic adapter = const bool.fromEnvironment('OLD_CLOSE')
          ? old.NativeHdrAdapter(
              write: write,
              detach: detach,
              active: () => true,
              message: (_) {},
              failure: fail,
            )
          : NativeHdrAdapter(
              write: write,
              detach: detach,
              active: () => true,
              message: (_) {},
              failure: fail,
            );
      await adapter.start();
      final preparing = adapter.prepare('pq') as Future<bool>;
      await Future<void>.delayed(Duration.zero);
      final delivered = Completer<void>();
      // ignore: deprecated_member_use
      binding.defaultBinaryMessenger.handlePlatformMessage(
        'yingyu/native_hdr',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('surface', {
            'owner': adapter.owner,
            'token': 7,
            'width': 1920,
            'height': 1080,
            'sdk': 37,
            'display': 0,
            'hdrTypes': [2],
          }),
        ),
        (_) => delivered.complete(),
      );
      await delivered.future;
      await entered.future;
      final closing = adapter.close() as Future<void>;
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      try {
        expect(
          detached,
          true,
          reason:
              'Close must signal native cancellation before waiting for pending HDR admission',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await preparing;
        await closing;
      }
    },
  );
  test(
    'controller invalidates pending HDR before waiting for its Surface lock',
    () async {
      final dynamic controller = const bool.fromEnvironment('OLD_CLOSE')
          ? before.ControllerClose()
          : current.ControllerClose();
      final release = Completer<void>();
      final held =
          controller.lock.synchronized(() => release.future) as Future<void>;
      await Future<void>.delayed(Duration.zero);
      final closing = controller.detachNativeHdrSurface() as Future<void>;
      await Future<void>.delayed(Duration.zero);
      try {
        expect(
          controller.closed,
          true,
          reason: 'A queued Surface lock must not delay the closing flag',
        );
        expect(controller.cancelled, true);
      } finally {
        release.complete();
        await held;
        await closing;
      }
    },
  );
}
