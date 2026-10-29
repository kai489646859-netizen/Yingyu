import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/native_hdr.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yingyu/native_hdr');
  const codec = StandardMethodCodec();
  test(
    'HDR-enabled Dolby waits for its in-flight local probe instead of permanently choosing SDR',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final probe = Completer<Map<String, Object?>>();
      final probeEntered = Completer<void>();
      final writes = <int>[];
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'watch') {
          return {
            'sdk': 34,
            'display': 0,
            'hdrTypes': [2],
          };
        }
        if (call.method == 'probe') {
          probeEntered.complete();
          return probe.future;
        }
        return null;
      });
      final adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async => false,
        preloadedWrite:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              writes.add(token);
              return true;
            },
        verifyPreloaded: () async => true,
        active: () => true,
        detach: () async {},
        message: (_) {},
        failure: fail,
      );
      try {
        final warm = adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        final delivered = Completer<void>();
        // ignore: deprecated_member_use
        binding.defaultBinaryMessenger.handlePlatformMessage(
          'yingyu/native_hdr',
          codec.encodeMethodCall(
            MethodCall('surface', {
              'owner': adapter.owner,
              'sdk': 34,
              'display': 0,
              'hdrTypes': [2],
              'token': 7,
              'width': 1920,
              'height': 1080,
            }),
          ),
          (_) => delivered.complete(),
        );
        await delivered.future;
        await probeEntered.future;
        final claim = adapter.claimWarm();
        // Model the actual local probe completing shortly after the demux hook.
        await Future<void>.delayed(const Duration(milliseconds: 25));
        probe.complete({'status': 'ready'});
        await warm;
        expect(await claim, isTrue);
        expect(writes, [7]);
        expect(await adapter.confirmWarm(), isTrue);
        expect(adapter.established, isTrue);
      } finally {
        if (!probe.isCompleted) probe.complete({'status': 'ready'});
        await adapter.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
  for (final reason in ['rgb10-config', 'dataspace-readback', 'egl-current']) {
    test(
      'rejected local probe $reason keeps SDR and records the exact safe reason',
      () async {
        final h = Hdr179Harness(binding, supported: true, result: reason);
        await h.install();
        try {
          final warm = h.adapter.warmDolby();
          await Future<void>.delayed(Duration.zero);
          await h.surface();
          await warm;
          expect(await h.adapter.claimWarm(), false);
          expect(h.writes, isEmpty);
          expect(h.messages.join(), contains('probe-$reason'));
        } finally {
          await h.close();
        }
      },
    );
  }
  test(
    'deadline cancels the candidate and a late successful probe cannot attach it',
    () async {
      final h = Hdr179Harness(binding, supported: true);
      await h.install();
      try {
        final warm = h.adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        await h.entered.future;
        expect(
          await h.adapter.claimWarm(wait: const Duration(milliseconds: 20)),
          false,
        );
        h.probe.complete({'status': 'ready'});
        await warm;
        expect(h.writes, isEmpty);
        expect(h.adapter.established, false);
        expect(h.messages.join(), contains('admission-deadline'));
      } finally {
        await h.close();
      }
    },
  );
  test(
    'exit cancels admission immediately without waiting for the blocked driver',
    () async {
      final h = Hdr179Harness(binding, supported: true);
      await h.install();
      try {
        final warm = h.adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        await h.entered.future;
        final claim = h.adapter.claimWarm();
        await h.adapter.close().timeout(const Duration(milliseconds: 100));
        expect(await claim.timeout(const Duration(milliseconds: 100)), false);
        h.probe.complete({'status': 'ready'});
        await warm;
        expect(h.writes, isEmpty);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'a cancelled admission cannot consume the next media candidate',
    () async {
      final h = Hdr179Harness(binding, supported: true);
      await h.install();
      try {
        final old = h.adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        await h.entered.future;
        final stale = h.adapter.claimWarm();
        h.adapter.cancelWarm();
        final next = h.adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        h.probe.complete({'status': 'ready'});
        await Future.wait([old, next]);
        expect(await stale, false);
        expect(h.writes, isEmpty);
        expect(await h.adapter.claimWarm(), true);
        expect(h.writes, [7]);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'unsupported display exits before allocating a window or invoking the driver',
    () async {
      final h = Hdr179Harness(binding, supported: false);
      await h.install();
      try {
        await h.adapter.warmDolby();
        expect(await h.adapter.claimWarm(), false);
        expect(h.adapter.request.value, isNull);
        expect(h.entered.isCompleted, false);
        expect(h.messages.join(), contains('hdr10-unsupported'));
      } finally {
        await h.close();
      }
    },
  );
}

class Hdr179Harness {
  Hdr179Harness(
    this.binding, {
    required this.supported,
    this.result,
    this.hdrTypes,
    this.outcomes,
    this.rejectPq = false,
  });
  final TestWidgetsFlutterBinding binding;
  final bool supported;
  final String? result;
  final List<int>? hdrTypes;
  final Map<String, String>? outcomes;
  final bool rejectPq;
  final probed = <String>[];
  final selected = <String>[];
  final probe = Completer<Map<String, Object?>>();
  final entered = Completer<void>();
  final writes = <int>[];
  final messages = <String>[];
  late NativeHdrAdapter adapter;
  Future<void> install() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('yingyu/native_hdr'),
      (call) async {
        if (call.method == 'watch') {
          return {
            'sdk': 34,
            'display': 0,
            'hdrTypes': hdrTypes ?? (supported ? [2] : <int>[]),
          };
        }
        if (call.method == 'probe') {
          if (!entered.isCompleted) entered.complete();
          final transfer = call.arguments['transfer'] as String;
          probed.add(transfer);
          if (outcomes != null) {
            return {'status': outcomes![transfer] ?? 'ready'};
          }
          return result == null ? probe.future : {'status': result};
        }
        return null;
      },
    );
    adapter = NativeHdrAdapter(
      write:
          ({
            required token,
            required width,
            required height,
            required transfer,
            required fill,
          }) async => false,
      preloadedWrite:
          ({
            required token,
            required width,
            required height,
            required transfer,
            required fill,
          }) async {
            writes.add(token);
            if (token > 0) selected.add(transfer);
            return !(rejectPq && token > 0 && transfer == 'pq');
          },
      verifyPreloaded: () async => true,
      active: () => true,
      detach: () async {},
      message: messages.add,
      failure: fail,
    );
  }

  Future<void> surface() async {
    final delivered = Completer<void>();
    // ignore: deprecated_member_use
    binding.defaultBinaryMessenger.handlePlatformMessage(
      'yingyu/native_hdr',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('surface', {
          'owner': adapter.owner,
          'sdk': 34,
          'display': 0,
          'hdrTypes': hdrTypes ?? [2],
          'token': 7,
          'width': 1920,
          'height': 1080,
        }),
      ),
      (_) => delivered.complete(),
    );
    await delivered.future;
  }

  Future<void> close() async {
    if (!probe.isCompleted) probe.complete({'status': 'ready'});
    await adapter.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('yingyu/native_hdr'),
      null,
    );
    debugDefaultTargetPlatformOverride = null;
  }
}
