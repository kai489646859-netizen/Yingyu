import 'package:flutter_test/flutter_test.dart';
import 'dolby_hdr177_test.dart' show Hdr177IO;
import 'hdr179_test.dart' show Hdr179Harness;
import 'host/output127/android.dart' as controller;
import 'native_hdr_output_test.dart' show OutputHarness;
import 'host/hdr100_current_record.dart' as record;
import 'package:yingyu/core/models.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/native_hdr_output.dart';
import 'package:yingyu/playback/native_hdr.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'valid empty automatic gpu context cannot reject the entire Dolby HDR snapshot',
    () async {
      final io = Hdr177IO()..values['gpu-context'] = '';
      expect(await io.arm(), isTrue);
      await io.restore();
      expect(io.values['gpu-context'], '');
    },
  );
  test('HDR10 is first and a rejected PQ probe tries HLG before SDR', () async {
    final h = Hdr179Harness(
      binding,
      supported: true,
      hdrTypes: [2, 3],
      outcomes: {'pq': 'rgb10-config', 'hlg': 'ready'},
    );
    await h.install();
    try {
      final warm = h.adapter.warmDolby();
      await Future<void>.delayed(Duration.zero);
      await h.surface();
      await warm;
      expect(await h.adapter.claimWarm(), true);
      expect(h.probed, ['pq', 'hlg']);
      expect(h.selected, ['hlg']);
      expect(await h.adapter.confirmWarm(), true);
      expect(h.adapter.dolbyHdrLabel, contains('HLG'));
    } finally {
      await h.close();
    }
  });
  test(
    'a rejected PQ output bridge restores then tries the valid HLG candidate',
    () async {
      final h = Hdr179Harness(
        binding,
        supported: true,
        hdrTypes: [2, 3],
        outcomes: {'pq': 'ready', 'hlg': 'ready'},
        rejectPq: true,
      );
      await h.install();
      try {
        final warm = h.adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        await warm;
        expect(await h.adapter.claimWarm(), true);
        expect(h.selected, ['pq', 'hlg']);
        expect(h.writes, [7, 0, 7]);
        expect(h.probed, ['pq', 'hlg']);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'a display declaring only HLG can map Dolby into real HLG without claiming HDR10',
    () async {
      final h = Hdr179Harness(
        binding,
        supported: true,
        hdrTypes: [3],
        outcomes: {'hlg': 'ready'},
      );
      await h.install();
      try {
        final warm = h.adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        await warm;
        expect(await h.adapter.claimWarm(), true);
        expect(h.probed, ['hlg']);
        expect(await h.adapter.confirmWarm(), true);
        expect(h.adapter.dolbyHdrLabel, '杜比映射 HLG HDR');
      } finally {
        await h.close();
      }
    },
  );
  test(
    'all declared HDR probes must reject before falling back to SDR',
    () async {
      final h = Hdr179Harness(
        binding,
        supported: true,
        hdrTypes: [2, 3],
        outcomes: {'pq': 'rgb10-config', 'hlg': 'dataspace-readback'},
      );
      await h.install();
      try {
        final warm = h.adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        await warm;
        expect(await h.adapter.claimWarm(), false);
        expect(h.probed, ['pq', 'hlg']);
        expect(h.selected, isEmpty);
        expect(h.adapter.established, false);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'HLG output changes the actual transfer/context and restores the original SDR snapshot',
    () async {
      final io = Hdr177IO();
      expect(
        await io.output.arm(
          surface: 7,
          width: 1920,
          height: 1080,
          texture: 900,
          textureWidth: 1920,
          textureHeight: 1080,
          transfer: 'hlg',
          read: io.read,
          write: io.write,
          current: () => true,
        ),
        true,
      );
      expect(io.values['gpu-context'], 'android-hdr-hlg');
      expect(io.values['target-trc'], 'hlg');
      io.ready = true;
      expect(await io.output.confirmed(io.read), true);
      await io.restore();
      expect(io.values['target-trc'], 'bt.1886');
    },
  );
  test(
    'ordinary Flutter surface callbacks cannot replace an active Dolby HDR owner',
    () async {
      final h = controller.AndroidHarness()..dolbyHdr = true;
      h.wid.value = 20;
      await h.widListener();
      expect(h.writes, isEmpty);
      expect(h.player.seeks, isEmpty);
    },
  );
  test('working HDR10 stays first and never probes or selects HLG', () async {
    final h = Hdr179Harness(
      binding,
      supported: true,
      hdrTypes: [2, 3],
      outcomes: {'pq': 'ready', 'hlg': 'ready'},
    );
    await h.install();
    try {
      final warm = h.adapter.warmDolby();
      await Future<void>.delayed(Duration.zero);
      await h.surface();
      await warm;
      expect(await h.adapter.claimWarm(), true);
      expect(h.probed, ['pq']);
      expect(h.selected, ['pq']);
      expect(await h.adapter.confirmWarm(), true);
      expect(h.adapter.dolbyHdrLabel, '杜比映射 HDR10');
    } finally {
      await h.close();
    }
  });
  test('the next media starts at HDR10 again after an HLG fallback', () async {
    final h = Hdr179Harness(
      binding,
      supported: true,
      hdrTypes: [2, 3],
      outcomes: {'pq': 'rgb10-config', 'hlg': 'ready'},
    );
    await h.install();
    try {
      final warm = h.adapter.warmDolby();
      await Future<void>.delayed(Duration.zero);
      await h.surface();
      await warm;
      expect(await h.adapter.claimWarm(), true);
      await h.adapter.resetAuto();
      h.outcomes!['pq'] = 'ready';
      final next = h.adapter.warmDolby();
      await Future<void>.delayed(Duration.zero);
      await h.surface();
      await next;
      expect(await h.adapter.claimWarm(), true);
      expect(h.probed, ['pq', 'hlg', 'pq']);
      expect(h.selected, ['hlg', 'pq']);
    } finally {
      await h.close();
    }
  });
  test(
    'the complete backend record/track-settle chain admits decoded Dolby after preloaded refusal',
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
        await h.run();
        expect(h.hdr.dolbyEstablished, true);
        expect(h.native.vo, 'gpu-next');
        expect(h.native.options['target-trc'], 'pq');
        expect(h.native.options['video-output-levels'], 'full');
      } finally {
        await h.hdr.close();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('yingyu/native_hdr'),
          null,
        );
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  test(
    'production priority leaves the decoded HDR10 fallback before considering HLG',
    () async {
      final h = Hdr179Harness(
        binding,
        supported: true,
        hdrTypes: [2, 3],
        outcomes: {'pq': 'ready', 'hlg': 'ready'},
        rejectPq: true,
      );
      await h.install();
      try {
        final warm = h.adapter.warmDolby(deferHlg: true);
        await Future<void>.delayed(Duration.zero);
        await h.surface();
        await warm;
        expect(await h.adapter.claimWarm(), false);
        expect(h.probed, ['pq']);
        expect(h.selected, ['pq']);
      } finally {
        await h.close();
      }
    },
  );
  for (final retired in [7, 99]) {
    test(
      'retired window $retired cannot invalidate a different active Dolby window',
      () async {
        final h = Hdr179Harness(binding, supported: true, result: 'ready');
        await h.install();
        try {
          final warm = h.adapter.warmDolby();
          await Future<void>.delayed(Duration.zero);
          await h.surface();
          await warm;
          expect(await h.adapter.claimWarm(), true);
          expect(await h.adapter.confirmWarm(), true);
          final done = Completer<void>();
          // ignore: deprecated_member_use
          binding.defaultBinaryMessenger.handlePlatformMessage(
            'yingyu/native_hdr',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('surface', {
                'owner': h.adapter.owner,
                'token': 0,
                'retiredToken': retired,
                'sdk': 37,
                'display': 0,
                'hdrTypes': [2],
              }),
            ),
            (_) => done.complete(),
          );
          await done.future;
          await Future<void>.delayed(Duration.zero);
          expect(h.adapter.established, retired != 7);
        } finally {
          await h.close();
        }
      },
    );
  }
  for (final failing in [false, true]) {
    test(
      'decoded Dolby keeps gpu-next and verifies HDR output; PQ renderer fails=$failing',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final io = DecodedDolbyIO()..rejectPq = failing;
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
        final adapter = NativeHdrAdapter(
          write: io.applyHdr,
          active: () => true,
          message: (_) {},
          failure: fail,
          detach: () async {
            await io.hdr.detachForClose(read: io.read, write: io.write);
          },
        );
        try {
          await adapter.start();
          final job = adapter.prepareDolby();
          await Future<void>.delayed(Duration.zero);
          final delivered = Completer<void>();
          // ignore: deprecated_member_use
          binding.defaultBinaryMessenger.handlePlatformMessage(
            'yingyu/native_hdr',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('surface', {
                'owner': adapter.owner,
                'sdk': 37,
                'display': 0,
                'hdrTypes': [2, 3],
                'token': 7,
                'width': 1920,
                'height': 1080,
              }),
            ),
            (_) => delivered.complete(),
          );
          await delivered.future;
          expect(await job, true);
          expect(adapter.dolbyEstablished, true);
          expect(io.vo, 'gpu-next');
          expect(io.options['target-trc'], failing ? 'hlg' : 'pq');
          expect(io.options['video-output-levels'], 'full');
          expect(
            io.writes.where((e) => e.$1 == 'vo' && e.$2 == 'gpu'),
            isEmpty,
          );
          expect(
            io.writes.where(
              (e) => [
                'hwdec',
                'vd-lavc-yingyu-dovi',
                'speed',
                'aid',
                'sid',
              ].contains(e.$1),
            ),
            isEmpty,
          );
          expect(
            adapter.dolbyHdrLabel,
            failing ? '杜比映射 HLG HDR' : '杜比映射 HDR10',
          );
        } finally {
          await adapter.close();
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

class DecodedDolbyIO extends OutputHarness {
  DecodedDolbyIO() {
    vo = 'gpu-next';
    options['video-output-levels'] = 'auto';
  }
  late final hdr = NativeHdrOutput(
    renderer: () => 'gpu-next',
    wait: (_) async {},
  );
  bool rejectPq = false;
  String selected = '1';
  @override
  Future<String> read(String key) async {
    if (key == 'pause') return 'yes';
    if (key == 'aid') return '1';
    if (key == 'vid') return selected;
    if (key == 'vo-configured') {
      return vo == 'gpu-next' && selected != 'no' ? 'yes' : 'no';
    }
    if (key == 'video-frame-info/interlaced') {
      return vo == 'gpu-next' && selected != 'no' ? 'no' : '';
    }
    if (key == 'current-vo' &&
        rejectPq &&
        options['gpu-context'] == 'android-hdr-pq') {
      return 'null';
    }
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == 'vid') selected = value == 'no' ? 'no' : '1';
    await super.write(key, value);
  }

  Future<bool> applyHdr({
    required int token,
    required int width,
    required int height,
    required String transfer,
    required bool fill,
  }) => hdr.apply(
    surface: token,
    width: width,
    height: height,
    transfer: transfer,
    fill: fill,
    textureSurface: 900,
    textureWidth: 1920,
    textureHeight: 1080,
    originalOutput: 'gpu-next',
    read: read,
    write: write,
  );
}
