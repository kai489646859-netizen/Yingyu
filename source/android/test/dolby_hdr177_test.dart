import 'dart:async';
import 'package:yingyu/core/models.dart';
import 'host/output127/current.dart' as hook;
import 'host/hdr100_current_record.dart' as record;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/dolby_hdr_output.dart';
import 'package:yingyu/playback/native_hdr.dart';
import 'package:yingyu/playback/media_notice.dart';

class Hdr177IO {
  final output = DolbyHdrOutput();
  final values = <String, String>{
    'gpu-context': 'android',
    'target-prim': 'bt.709',
    'target-trc': 'bt.1886',
    'target-peak': 'auto',
    'tone-mapping': 'bt.2390',
    'dither': 'fruit',
    'dither-depth': '8',
    'video-output-levels': 'auto',
    'panscan': '0',
    'vid': 'auto',
    'vo': 'gpu-next',
    'wid': '900',
  };
  final writes = <(String, String)>[];
  String profile = '5', container = 'mov,mp4,m4a,3gp,3g2,mj2';
  String? reject;
  bool live = false, ready = false, selected = true, current = true;
  Future<String> read(String key) async {
    if (key == 'yingyu-preloaded-dolby-vision-profile' ||
        key == 'current-tracks/video/dolby-vision-profile') {
      return profile;
    }
    if (key == 'file-format') return container;
    if (key == 'idle-active') return live ? 'no' : 'yes';
    if (key == 'time-pos') return '42.125';
    if (key == 'current-vo') return values['vo']!;
    if (key == 'vo-configured') return ready ? 'yes' : 'no';
    if (key == 'video-frame-info/interlaced') return ready ? 'no' : '';
    if (key == 'seeking') return 'no';
    if (key == 'vid') return selected ? '1' : 'no';
    return values[key.replaceFirst('options/', '')] ?? '';
  }

  Future<void> write(String key, String value) async {
    writes.add((key, value));
    if (key == reject) {
      reject = null;
      return;
    }
    if (values.containsKey(key)) values[key] = value;
    if (key == 'vid') selected = true;
  }

  Future<bool> arm({double peak = 0}) => output.arm(
    surface: 7,
    width: 1920,
    height: 1080,
    texture: 900,
    textureWidth: 1920,
    textureHeight: 1080,
    position: '31.5',
    peak: peak,
    read: read,
    write: write,
    current: () => current,
  );
  Future<void> restore({
    bool recover = false,
    Future<void> Function(String)? refresh,
  }) => output.restore(
    texture: 900,
    width: 1920,
    height: 1080,
    read: read,
    write: write,
    recover: recover,
    refresh: refresh,
    current: () => current,
  );
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'predecoded HDR preserves source mapping, full RGB range and neutral adjustments',
    () async {
      final io = Hdr177IO(), before = <String, String>{};
      before.addAll(io.values);
      expect(await io.arm(peak: 650.25), isTrue);
      expect(io.values['target-prim'], 'bt.2020');
      expect(io.values['target-trc'], 'pq');
      expect(io.values['target-peak'], '650');
      expect(io.values['dither-depth'], '10');
      expect(io.values['video-output-levels'], 'full');
      expect(io.writes.first, ('vo', 'null'));
      expect(io.writes.last, ('vo', 'gpu-next'));
      expect(
        io.writes.any(
          (e) => const {
            'gamma',
            'brightness',
            'contrast',
            'hwdec',
            'pause',
            'speed',
            'aid',
            'sid',
            'start',
            'tone-mapping-param',
          }.contains(e.$1),
        ),
        isFalse,
      );
      expect(
        await io.output.confirmed(io.read),
        isFalse,
        reason: 'A requested HDR target is not a real configured frame.',
      );
      io.ready = true;
      expect(await io.output.confirmed(io.read), isTrue);
      await io.restore();
      expect(io.values, before);
      expect(
        io.writes.any((e) => e.$1 == 'vid'),
        isFalse,
        reason:
            'Predecoder rollback must not select video before hook continuation.',
      );
    },
  );
  test('all initial parameter rejections restore exact SDR snapshot', () async {
    for (final key in [
      'gpu-context',
      'target-prim',
      'target-trc',
      'dither-depth',
      'video-output-levels',
      'wid',
    ]) {
      final io = Hdr177IO();
      final before = Map<String, String>.of(io.values);
      io.reject = key;
      expect(await io.arm(), isFalse, reason: key);
      expect(io.values, before, reason: key);
      expect(io.output.active, isFalse);
    }
  });
  test(
    'unknown profile/container and superseded media do not touch SDR',
    () async {
      for (final profile in ['0', '', '未提供', '4', '9', '11']) {
        final io = Hdr177IO()..profile = profile;
        expect(await io.arm(), isFalse);
        expect(io.writes, isEmpty);
      }
      final io = Hdr177IO()..container = 'mpegts';
      expect(await io.arm(), isFalse);
      expect(io.writes, isEmpty);
      io.container = 'matroska,webm';
      io.current = false;
      expect(await io.arm(), isFalse);
      expect(io.writes, isEmpty);
      await io.restore();
      expect(io.writes, isEmpty);
    },
  );
  test(
    'only actual fallback uses the current exact position, with no track or pause changes',
    () async {
      final io = Hdr177IO();
      final before = Map<String, String>.of(io.values);
      expect(await io.arm(), isTrue);
      io.live = true;
      final positions = <String>[];
      await io.restore(
        recover: true,
        refresh: (position) async {
          positions.add(position);
          io.ready = true;
        },
      );
      expect(positions, ['42.125']);
      expect(io.values, before);
      expect(
        io.writes.any(
          (e) => const {'vid', 'aid', 'sid', 'pause', 'speed'}.contains(e.$1),
        ),
        isFalse,
      );
    },
  );
  test(
    'changed media cannot receive an old fallback seek and close never rebuilds',
    () async {
      final io = Hdr177IO();
      expect(await io.arm(), isTrue);
      io.live = true;
      io.current = false;
      await io.restore(recover: true, refresh: (_) async => fail('stale seek'));
      final closing = Hdr177IO();
      expect(await closing.arm(), isTrue);
      closing.writes.clear();
      closing.output.cancelForClose();
      await closing.output.detach(closing.write);
      expect(closing.writes, [('vo', 'null'), ('wid', '0')]);
      expect(closing.output.active, isFalse);
    },
  );
  test(
    'unknown desired screen luminance stays auto; invalid claims do not change display capability',
    () async {
      for (final peak in [
        0.0,
        -1.0,
        double.nan,
        double.infinity,
        20.0,
        10001.0,
      ]) {
        final io = Hdr177IO();
        expect(await io.arm(peak: peak), isTrue);
        expect(io.values['target-peak'], 'auto');
      }
      expect(
        OutputCapabilities.parse({'hdrMaxLuminance': 710.5}).maxLuminance,
        710.5,
      );
      expect(
        OutputCapabilities.parse({'hdrMaxLuminance': double.nan}).maxLuminance,
        0,
      );
    },
  );
  test(
    'notice describes confirmed output instead of Dolby capability alone',
    () {
      const streams = [
        {'Type': 'Video', 'DoviProfile': 5},
      ];
      expect(
        mediaNotice(bluray: false, streams: streams, dolbyMapped: true),
        '杜比映射 SDR',
      );
      expect(
        mediaNotice(
          bluray: false,
          streams: streams,
          dolbyMapped: true,
          nativeHdr: true,
        ),
        '杜比映射 HDR10',
      );
    },
  );

  test(
    'HDR off bypasses the complete Dolby admission hook; HDR on dispatches local preparation and admission',
    () async {
      final off = hook.HookHarness();
      await off.preload();
      expect(off.hdr.warms, 0);
      expect(off.hdr.claims, 0);
      expect(off.video.mapped, isTrue);
      final on = hook.HookHarness()..nativeHdr = true;
      await on.preload().timeout(const Duration(milliseconds: 100));
      expect(on.hdr.warms, 1);
      expect(on.hdr.claims, 1);
      expect(on.video.prepared, isTrue);
    },
  );
  test(
    'complete ordinary HDR10 and HLG output recording stays SDR when the setting is off',
    () async {
      for (final gamma in ['pq', 'hlg']) {
        final h = record.RecordHarness(gamma: gamma)..nativeHdr = false;
        h.route = PlaybackRoute(
          url: 'http://127.0.0.1/synthetic',
          sourceId: 'fixture',
          sessionId: 'fixture',
          streams: const [],
          headers: const {},
        );
        await h.run();
        expect(h.hdr.request.value, isNull);
        expect(h.hdr.established, isFalse);
        expect(h.native.options['target-trc'], 'bt.1886');
        expect(h.native.options['target-prim'], 'bt.709');
        expect(h.native.options['dither-depth'], '8');
        expect(
          h.native.writes.any(
            (e) => e.$2 == 'android-hdr-pq' || e.$2 == 'android-hdr-hlg',
          ),
          isFalse,
        );
        await h.close();
      }
    },
  );
  test(
    'runtime recovery owns only one failure and cannot complete into a new media generation',
    () async {
      final r = DolbyHdrRecovery();
      final held = Completer<void>();
      var restored = 0, failed = 0;
      final task = r.reject(
        restore: () => held.future,
        current: () => true,
        restored: () => restored++,
        failure: () => failed++,
      );
      expect(
        r.holdsInitializationError(
          'vo/gpu-next',
          'Failed to initialize video output',
        ),
        isTrue,
      );
      expect(r.holdsInitializationError('ad', 'audio failed'), isFalse);
      expect(
        r.holdsInitializationError('ffmpeg/video', 'mapping failed'),
        isFalse,
      );
      await r.reject(
        restore: () async => fail('second restore'),
        current: () => true,
        restored: () {},
        failure: () {},
      );
      r.reset();
      held.complete();
      await task;
      expect(restored, 0);
      expect(failed, 0);
      expect(r.recovering, isFalse);
      await r.reject(
        restore: () async => throw StateError('real restoration failure'),
        current: () => true,
        restored: () => restored++,
        failure: () => failed++,
      );
      expect(failed, 1);
    },
  );
  test(
    'viewport fill restores its snapshot while phone panscan stays owned by the phone canvas',
    () async {
      final io = Hdr177IO();
      await io.arm();
      expect(
        await io.output.resize(
          width: 1280,
          height: 720,
          fill: true,
          read: io.read,
          write: io.write,
        ),
        isTrue,
      );
      expect(io.values['panscan'], '1');
      expect(
        await io.output.resize(
          width: 20000,
          height: 720,
          fill: false,
          read: io.read,
          write: io.write,
        ),
        isFalse,
      );
      await io.restore();
      expect(io.values['panscan'], '0');
      final phone = Hdr177IO();
      expect(
        await phone.output.arm(
          surface: 7,
          width: 1920,
          height: 1080,
          texture: 900,
          textureWidth: 1920,
          textureHeight: 1080,
          fill: true,
          keepPanscan: true,
          read: phone.read,
          write: phone.write,
          current: () => true,
        ),
        isTrue,
      );
      await phone.output.resize(
        width: 1280,
        height: 720,
        fill: false,
        read: phone.read,
        write: phone.write,
      );
      await phone.restore();
      expect(phone.writes.where((e) => e.$1 == 'panscan'), isEmpty);
    },
  );
  group('parallel HDR window', () {
    const channel = MethodChannel('yingyu/native_hdr');
    const codec = StandardMethodCodec();
    var supported = true;
    Completer<Map<String, String>>? probe;
    final calls = <int>[];
    late NativeHdrAdapter adapter;
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      supported = true;
      probe = null;
      calls.clear();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'watch') {
          return {
            'sdk': 34,
            'display': 0,
            'hdrTypes': supported ? [2] : <int>[],
          };
        }
        if (call.method == 'probe') {
          return probe == null ? {'status': 'ready'} : await probe!.future;
        }
        return null;
      });
      adapter = NativeHdrAdapter(
        write:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async => throw StateError('legacy HDR path'),
        preloadedWrite:
            ({
              required token,
              required width,
              required height,
              required transfer,
              required fill,
            }) async {
              calls.add(token);
              return token > 0;
            },
        verifyPreloaded: () async => true,
        active: () => true,
        detach: () async {},
        message: (_) {},
        failure: (error) => fail(error),
      );
    });
    tearDown(() async {
      await adapter.close();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });
    Future<void> surface() async {
      final done = Completer<void>();
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
        (_) => done.complete(),
      );
      await done.future;
      await Future<void>.delayed(Duration.zero);
    }

    test(
      'prepared window does not establish HDR until the actual frame is confirmed',
      () async {
        final warm = adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await surface();
        await warm;
        expect(adapter.established, isFalse);
        expect(calls, isEmpty);
        expect(await adapter.claimWarm(), isTrue);
        expect(calls, [7]);
        expect(adapter.established, isFalse);
        expect(await adapter.confirmWarm(), isTrue);
        expect(adapter.established, isTrue);
        await adapter.resetAuto();
        expect(calls, [7, 0]);
        expect(adapter.established, isFalse);
      },
    );
    test(
      'explicit zero-wait admission rejects a slow probe and ignores its late completion',
      () async {
        probe = Completer<Map<String, String>>();
        final warm = adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await surface();
        expect(
          await adapter
              .claimWarm(wait: Duration.zero)
              .timeout(const Duration(milliseconds: 50)),
          isFalse,
        );
        expect(calls, isEmpty);
        expect(adapter.request.value, isNull);
        probe!.complete({'status': 'ready'});
        await warm;
        expect(adapter.established, isFalse);
        expect(calls, isEmpty);
      },
    );
    test(
      'display capability loss restores once and cannot re-admit the same media',
      () async {
        final warm = adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await surface();
        await warm;
        expect(await adapter.claimWarm(), isTrue);
        expect(await adapter.confirmWarm(), isTrue);
        final done = Completer<void>();
        // ignore: deprecated_member_use
        binding.defaultBinaryMessenger.handlePlatformMessage(
          'yingyu/native_hdr',
          codec.encodeMethodCall(
            MethodCall('changed', {
              'owner': adapter.owner,
              'sdk': 34,
              'display': 1,
              'hdrTypes': <int>[],
            }),
          ),
          (_) => done.complete(),
        );
        await done.future;
        await Future<void>.delayed(Duration.zero);
        expect(adapter.established, isFalse);
        expect(calls, [7, 0]);
        expect(await adapter.claimWarm(), isFalse);
        expect(calls, [7, 0]);
      },
    );
    test(
      'closing while a probe is pending cannot attach a late HDR window',
      () async {
        probe = Completer<Map<String, String>>();
        final warm = adapter.warmDolby();
        await Future<void>.delayed(Duration.zero);
        await surface();
        await adapter.close();
        probe!.complete({'status': 'ready'});
        await warm;
        expect(calls, isEmpty);
        expect(adapter.established, isFalse);
      },
    );
    test(
      'unsupported display never requests a candidate or writes renderer settings',
      () async {
        supported = false;
        await adapter.warmDolby();
        expect(adapter.request.value, isNull);
        expect(await adapter.claimWarm(), isFalse);
        expect(calls, isEmpty);
      },
    );
  });
}
