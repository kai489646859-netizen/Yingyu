import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/native_hdr.dart';

void main() {
  const pq = {
    'video-params/primaries': 'bt.2020',
    'video-params/gamma': 'pq',
    'video-params/colormatrix': 'bt.2020-ncl',
  };
  const hlg = {
    'video-params/primaries': 'bt.2020',
    'video-params/gamma': 'hlg',
  };
  const screen = OutputCapabilities(sdk: 34, display: 0, hdr: {1, 2, 3});
  test('selected native track/frame determines HDR10 HLG and SDR', () {
    expect(detectVideoRange(pq, '0'), DetectedVideoRange.hdr10);
    expect(detectVideoRange(hlg, '0'), DetectedVideoRange.hlg);
    expect(
      detectVideoRange({
        'video-params/primaries': 'bt.709',
        'video-params/gamma': 'bt.1886',
      }, '0'),
      DetectedVideoRange.sdr,
    );
  });
  test('actual Dolby profile and RPU color each take precedence over PQ', () {
    expect(detectVideoRange(pq, '5'), DetectedVideoRange.dolby);
    expect(detectVideoRange(pq, '8'), DetectedVideoRange.dolby);
    expect(
      detectVideoRange({...pq, 'video-params/colormatrix': 'dolbyvision'}, '0'),
      DetectedVideoRange.dolby,
    );
    expect(
      detectVideoRange({...pq, 'video-params/colormatrix': 'dolbyvision'}, ''),
      DetectedVideoRange.dolby,
    );
  });
  test('missing invalid metadata and wide gamut alone cannot activate HDR', () {
    for (final profile in ['', '未提供', '-1', '11']) {
      expect(detectVideoRange(pq, profile), DetectedVideoRange.unknown);
    }
    expect(
      detectVideoRange({'video-params/primaries': 'bt.2020'}, '0'),
      DetectedVideoRange.unknown,
    );
    expect(
      detectVideoRange({
        'video-params/primaries': 'bt.709',
        'video-params/gamma': 'pq',
      }, '0'),
      DetectedVideoRange.unknown,
    );
  });
  test(
    'detected HDR is selected using current screen not phone/tablet labels',
    () {
      String? plan(DetectedVideoRange source, OutputCapabilities caps) =>
          nativeHdrTransfer(
            requested: true,
            disc: false,
            source: source,
            container: 'matroska,webm',
            capabilities: caps,
          );
      expect(plan(DetectedVideoRange.hdr10, screen), 'pq');
      expect(plan(DetectedVideoRange.hlg, screen), 'hlg');
      expect(plan(DetectedVideoRange.dolby, screen), isNull);
      expect(plan(DetectedVideoRange.unknown, screen), isNull);
      expect(plan(DetectedVideoRange.sdr, screen), isNull);
      expect(
        plan(
          DetectedVideoRange.hdr10,
          const OutputCapabilities(sdk: 34, display: 1, hdr: {3}),
        ),
        isNull,
      );
      expect(
        plan(
          DetectedVideoRange.hlg,
          const OutputCapabilities(sdk: 33, display: 1, hdr: {3}),
        ),
        'hlg',
      );
    },
  );
  test(
    'unavailable display, old API, raw/disc and disabled preference stay compatible',
    () {
      for (final caps in [
        const OutputCapabilities(),
        const OutputCapabilities(sdk: 34, hdr: {2}),
        const OutputCapabilities(sdk: 32, display: 0, hdr: {2}),
      ]) {
        expect(
          nativeHdrTransfer(
            requested: true,
            disc: false,
            source: DetectedVideoRange.hdr10,
            container: 'matroska',
            capabilities: caps,
          ),
          isNull,
        );
      }
      for (final container in ['', 'mpegts', 'rawvideo']) {
        expect(
          nativeHdrTransfer(
            requested: true,
            disc: false,
            source: DetectedVideoRange.hdr10,
            container: container,
            capabilities: screen,
          ),
          isNull,
        );
      }
      expect(
        nativeHdrTransfer(
          requested: true,
          disc: true,
          source: DetectedVideoRange.hdr10,
          container: 'matroska',
          capabilities: screen,
        ),
        isNull,
      );
      expect(
        nativeHdrTransfer(
          requested: false,
          disc: false,
          source: DetectedVideoRange.hdr10,
          container: 'matroska',
          capabilities: screen,
        ),
        isNull,
      );
    },
  );
  test(
    'capabilities distinguish declaration, anticipated audio and unknown',
    () {
      final c = OutputCapabilities.parse({
        'sdk': 34,
        'display': 0,
        'hdrTypes': [2, 3, 'bad'],
        'anticipatedAudioTypes': [8, 9, 999],
      });
      expect(c.hdr, {2, 3});
      expect(c.displayDescription, contains('屏幕声明'));
      expect(c.audioDescription, contains('系统预期路由'));
      expect(c.audioDescription, contains('蓝牙'));
      expect(c.audioDescription, contains('HDMI'));
      expect(const OutputCapabilities().audioDescription, contains('未提供'));
    },
  );
  test(
    'HDR preference defaults off and survives an AppStore recreation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final first = AppStore(prefs);
      expect(first.nativeHdr, isFalse);
      await first.setNativeHdr(true);
      expect(AppStore(prefs).nativeHdr, isTrue);
      await first.setNativeHdr(false);
      expect(AppStore(prefs).nativeHdr, isFalse);
      expect(prefs.getKeys(), {'yingyu.playback.nativeHdr.v1'});
    },
  );
}
