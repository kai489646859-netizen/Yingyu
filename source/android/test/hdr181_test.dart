import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yingyu/core/models.dart';
import 'host/hdr181_record.dart' as record;
import 'package:flutter_test/flutter_test.dart';
import 'dolby_hdr177_test.dart' show Hdr177IO;
import 'host/hdr181_controller.dart';

class FloatPeakIO extends Hdr177IO {
  @override
  Future<void> write(String key, String value) async {
    await super.write(key, value);
    if (key == 'target-peak' && double.tryParse(value) != null) {
      final f = Float32List(1)..[0] = double.parse(value);
      values[key] = f[0].toStringAsFixed(6);
    }
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real controller admits decoded Dolby HDR10 while preserving gpu-next',
    () async {
      final c = Controller181()..mapped = true;
      expect(await c.attempt('pq'), true);
      expect(c.platform.vo, 'gpu-next');
      expect(c.platform.values['gpu-context'], 'android-hdr-pq');
      await c.restore();
      expect(c.platform.values['gpu-context'], '');
    },
  );
  test(
    'display peak uses the pinned integer option and survives float readback',
    () async {
      final io = FloatPeakIO();
      expect(await io.arm(peak: 600.1), true, reason: io.output.status);
      expect(double.parse(io.values['target-peak']!), 600);
      await io.restore();
      expect(io.values['target-peak'], 'auto');
    },
  );
  test(
    'complete predecoded controller rounds peak and excludes a simultaneous second HDR owner',
    () async {
      final c = Controller181()..mapped = true;
      expect(
        await c.setPreloadedDolbyHdrSurface(
          token: 7,
          width: 1920,
          height: 1080,
          transfer: 'pq',
          fill: false,
          peak: 650.25,
        ),
        true,
      );
      expect(c.platform.values['target-peak'], '650');
      final count = c.platform.writes.length;
      expect(await c.attempt('hlg'), false);
      expect(c.status, 'admission-preloaded-owner-active');
      expect(c.platform.writes.length, count);
      await c.setPreloadedDolbyHdrSurface(
        token: 0,
        width: 1,
        height: 1,
        transfer: 'pq',
        fill: false,
      );
      expect(c.platform.values['target-peak'], 'auto');
      expect(c.platform.values['gpu-context'], '');
      expect(await c.attempt('pq'), true);
      await c.restore();
    },
  );
  for (final mapped in [false, true]) {
    test(
      'complete controller rejected HDR10 restores before HLG, Dolby=$mapped',
      () async {
        final c = Controller181()..mapped = mapped;
        c.platform.rejectPq = true;
        expect(await c.attempt('pq'), false);
        expect(c.platform.values['gpu-context'], '');
        expect(c.platform.vo, mapped ? 'gpu-next' : 'gpu');
        expect(await c.attempt('hlg'), true);
        expect(c.platform.vo, mapped ? 'gpu-next' : 'gpu');
        expect(c.platform.values['gpu-context'], 'android-hdr-hlg');
        await c.restore();
      },
    );
  }

  for (final preloaded in [false, true]) {
    for (final reject in [false, true]) {
      test(
        'whole backend to real controller HDR path, predecoded=$preloaded PQ rejected=$reject',
        () async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('yingyu/native_hdr'),
            (call) async {
              if (call.method == 'watch') {
                return {
                  'sdk': 37,
                  'display': 0,
                  'hdrTypes': [2, 3],
                };
              }
              if (call.method == 'probe') return {'status': 'ready'};
              return null;
            },
          );
          final h = record.RecordHarness(profile: '5', gamma: 'bt.1886')
            ..enableDolby();
          h.native.rejectPq = reject;
          h.route = PlaybackRoute(
            url: 'http://127.0.0.1/synthetic',
            sourceId: 'generated',
            sessionId: 'generated',
            headers: const {},
            streams: const [],
          );
          h.hdr.request.addListener(() {
            if (h.hdr.request.value == null) return;
            scheduleMicrotask(() {
              // ignore: deprecated_member_use
              binding.defaultBinaryMessenger.handlePlatformMessage(
                'yingyu/native_hdr',
                const StandardMethodCodec().encodeMethodCall(
                  MethodCall('surface', {
                    'owner': h.hdr.owner,
                    'sdk': 37,
                    'display': 0,
                    'hdrTypes': [2, 3],
                    'token': 7,
                    'width': 1920,
                    'height': 1080,
                  }),
                ),
                (_) {},
              );
            });
          });
          try {
            if (preloaded) {
              await h.hdr.warmDolby(deferHlg: true);
              expect(await h.hdr.claimWarm(), true);
            }
            await h.run();
            expect(h.failed, false);
            expect(
              h.hdr.dolbyEstablished,
              true,
              reason: '${h.hdr.status};${h.video.controller.status}',
            );
            expect(h.native.vo, 'gpu-next');
            expect(h.native.values['target-trc'], reject ? 'hlg' : 'pq');
            expect(h.native.values['video-output-levels'], 'full');
            expect(
              h.native.writes.where(
                (e) => [
                  'hwdec',
                  'speed',
                  'aid',
                  'sid',
                  'vd-lavc-yingyu-dovi',
                ].contains(e.$1),
              ),
              isEmpty,
            );
          } finally {
            await h.close();
            binding.defaultBinaryMessenger.setMockMethodCallHandler(
              const MethodChannel('yingyu/native_hdr'),
              null,
            );
            debugDefaultTargetPlatformOverride = null;
          }
        },
      );
    }
  }
}
