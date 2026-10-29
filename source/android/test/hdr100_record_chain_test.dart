import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'host/hdr100_old_record.dart' as old;
import 'host/hdr100_current_record.dart' as current;

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
              'sdk': 34,
              'display': 0,
              'hdrTypes': [2, 3],
              'anticipatedAudioTypes': [2],
            }
          : null,
    );
  });
  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  PlaybackRoute route() => PlaybackRoute(
    url: 'http://127.0.0.1/synthetic',
    sourceId: 'fixture',
    sessionId: 'fixture',
    headers: const {},
    streams: const [],
  );
  void provideSurface(dynamic hdr) {
    hdr.request.addListener(() {
      if (hdr.request.value == null) return;
      scheduleMicrotask(() {
        // Test-side Android callback; no Surface or real native player exists.
        // ignore: deprecated_member_use
        binding.defaultBinaryMessenger.handlePlatformMessage(
          'yingyu/native_hdr',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('surface', {
              'owner': hdr.owner,
              'token': 7,
              'width': 3840,
              'height': 2512,
              'sdk': 34,
              'display': 0,
              'hdrTypes': [2, 3],
            }),
          ),
          (_) {},
        );
      });
    });
  }

  test(
    'full delivered/current MKV chain reproduces silent skip then establishes actual output transaction',
    () async {
      final before = old.RecordHarness()..route = route();
      provideSurface(before.hdr);
      await before.run();
      expect(before.hdr.established, false);
      expect(
        before.native.writes.any(
          (e) => e.$1 == 'gpu-context' && e.$2 == 'android-hdr-pq',
        ),
        false,
      );
      await before.close();
      final now = current.RecordHarness()..route = route();
      provideSurface(now.hdr);
      await now.run();
      expect(now.failed, false);
      expect(now.hdr.established, true);
      expect(now.video.output.active, true);
      expect(now.native.writes, contains(('gpu-context', 'android-hdr-pq')));
      expect(now.sourceNotice, contains('HDR10 · 高动态范围'));
      expect(now.sourceNotice, isNot(contains('Dolby')));
      expect(
        now.native.writes.where(
          (e) => const {
            'loadfile',
            'seek',
            'pause',
            'speed',
            'aid',
            'sid',
          }.contains(e.$1),
        ),
        isEmpty,
      );
      await now.close();
      expect(now.video.output.active, false);
      expect(now.native.vo, 'gpu');
      expect(now.native.wid, '900');
    },
  );
  test(
    'new optional surface wait is bounded and keeps compatible output without a surface',
    () async {
      final now = current.RecordHarness()..route = route();
      final clock = Stopwatch()..start();
      await now.run();
      expect(now.hdr.established, false);
      expect(now.failed, false);
      expect(clock.elapsedMilliseconds, lessThan(1000));
      expect(
        now.native.writes.any(
          (e) => e.$1 == 'gpu-context' && e.$2.startsWith('android-hdr'),
        ),
        false,
      );
      expect(now.sourceNotice, contains('SDR'));
      await now.close();
    },
  );
  for (final item in [
    (profile: '8', gamma: 'pq'),
    (profile: '', gamma: 'pq'),
    (profile: '0', gamma: 'bt.1886'),
  ]) {
    test(
      'actual Dolby unknown and SDR never activate new HDR: $item',
      () async {
        final now = current.RecordHarness(
          profile: item.profile,
          gamma: item.gamma,
        )..route = route();
        provideSurface(now.hdr);
        await now.run();
        expect(now.hdr.established, false);
        expect(now.failed, false);
        expect(
          now.native.writes.any(
            (e) => e.$1 == 'gpu-context' && e.$2.startsWith('android-hdr'),
          ),
          false,
        );
        await now.close();
      },
    );
  }
}
