import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/native_hdr_output.dart';
import 'package:yingyu/playback/runtime_health.dart';

class RealOutputFixture {
  final output = NativeHdrOutput(wait: (_) async {});
  final options = <String, String>{
    'gpu-context': 'android',
    'target-prim': 'bt.709',
    'target-trc': 'bt.1886',
    'target-peak': 'auto',
    'tone-mapping': 'bt.2390',
    'dither': 'fruit',
    'dither-depth': '8',
    'panscan': '0',
    'vid': 'auto',
  };
  final writes = <(String, String)>[];
  bool selected = true, loseVideo = true, refuseVideo = false;
  bool hdrAvailable = false, noRestoredFrame = false, rejected = false;
  String requestedVo = 'gpu', actualVo = 'gpu', wid = '900';
  Future<String> read(String key) async {
    if (key == 'options/vo') return requestedVo;
    if (key == 'options/wid') return wid;
    if (key == 'vid') return selected ? '1' : 'no';
    if (key == 'current-vo') return actualVo;
    if (key == 'vo-configured') return actualVo == 'gpu' ? 'yes' : 'no';
    if (key == 'video-frame-info/interlaced') {
      return actualVo == 'gpu' && !(rejected && noRestoredFrame) ? 'no' : '';
    }
    return options[key.replaceFirst('options/', '')] ?? '';
  }

  Future<void> write(String key, String value) async {
    writes.add((key, value));
    if (key == 'vo') {
      requestedVo = value;
      if (value == 'gpu' &&
          options['gpu-context']!.startsWith('android-hdr') &&
          !hdrAvailable) {
        rejected = true;
        if (loseVideo) selected = false;
        actualVo = '';
      } else {
        actualVo = selected ? value : '';
      }
    } else if (key == 'wid') {
      wid = value;
    } else if (key == 'vid') {
      if (!refuseVideo) {
        selected = value == '1' || value == 'auto';
        actualVo = selected ? requestedVo : '';
      }
    } else if (options.containsKey(key)) {
      options[key] = value;
    }
  }

  Future<bool> apply({int token = 7, int texture = 900}) => output.apply(
    surface: token,
    width: 3840,
    height: 2512,
    transfer: 'pq',
    fill: false,
    textureSurface: texture,
    textureWidth: 3840,
    textureHeight: 2512,
    originalOutput: 'gpu',
    read: read,
    write: write,
  );
}

RuntimeSample missing(
  int seconds, {
  bool playing = true,
  bool buffering = false,
  bool seeking = false,
  bool ready = false,
}) => RuntimeSample(
  now: Duration(seconds: seconds),
  position: Duration(seconds: 621 + seconds),
  audioPosition: Duration(seconds: 621 + seconds),
  playing: playing,
  buffering: buffering,
  seeking: seeking,
  cachePaused: false,
  outputReady: ready,
  hardware: ready ? 'mediacodec-copy' : '',
);

void main() {
  test(
    'unknown original selection or color options never disturb healthy output',
    () async {
      for (final missing in [
        'vid',
        'target-prim',
        'target-trc',
        'target-peak',
        'tone-mapping',
        'dither',
        'dither-depth',
        'panscan',
      ]) {
        final f = RealOutputFixture();
        f.options.remove(missing);
        expect(await f.apply(), false);
        expect(f.writes, isEmpty);
        expect(f.actualVo, 'gpu');
        expect(f.output.active, false);
      }
      final f = RealOutputFixture();
      expect(await f.apply(texture: 0), false);
      expect(f.writes, isEmpty);
    },
  );
  test('automatic GPU context is valid and is restored exactly', () async {
    final f = RealOutputFixture()..hdrAvailable = true;
    f.options['gpu-context'] = '';
    final before = Map.of(f.options);
    expect(await f.apply(), true);
    expect(f.options['gpu-context'], 'android-hdr-pq');
    expect(await f.apply(token: 0), false);
    expect(f.options, before);
    expect(f.actualVo, 'gpu');
    expect(f.output.active, false);
  });
  test(
    'lost compatibility Surface is a real failure until a usable Surface returns',
    () async {
      final f = RealOutputFixture()..hdrAvailable = true;
      expect(await f.apply(), true);
      await expectLater(f.apply(token: 0, texture: 0), throwsStateError);
      expect(f.output.active, true);
      expect(f.actualVo, 'null');
      expect(f.options['target-trc'], 'bt.1886');
      expect(f.options['target-prim'], 'bt.709');
      expect(await f.apply(token: 0), false);
      expect(f.output.active, false);
      expect(f.actualVo, 'gpu');
    },
  );
  test(
    'HDR rejection repairs a deselected video and confirms real output',
    () async {
      final f = RealOutputFixture();
      final before = Map.of(f.options);
      expect(await f.apply(), false);
      expect(f.options, before);
      expect(f.wid, '900');
      expect(f.actualVo, 'gpu');
      expect(f.selected, true);
      expect(f.output.active, false);
      expect(f.writes.where((w) => w.$1 == 'vid'), [
        ('vid', '1'),
        ('vid', 'auto'),
      ]);
      expect(
        f.writes.any(
          (w) => const {'aid', 'sid', 'pause', 'seek', 'speed'}.contains(w.$1),
        ),
        false,
      );
    },
  );
  test(
    'restored options cannot conceal an unrecoverable video selection',
    () async {
      final f = RealOutputFixture()..refuseVideo = true;
      await expectLater(f.apply(), throwsStateError);
      expect(f.requestedVo, 'gpu');
      expect(f.actualVo, '');
      expect(f.output.active, true);
    },
  );
  test(
    'a restored VO without a current frame is not successful fallback',
    () async {
      final f = RealOutputFixture()..noRestoredFrame = true;
      await expectLater(f.apply(), throwsStateError);
      expect(f.actualVo, 'gpu');
      expect(f.output.active, true);
    },
  );
  test(
    'healthy compatibility fallback does not reselect video needlessly',
    () async {
      final f = RealOutputFixture()..loseVideo = false;
      expect(await f.apply(), false);
      expect(f.writes.any((w) => w.$1 == 'vid'), false);
    },
  );
  test(
    'successful HDR and later restoration retain exactly the source colors',
    () async {
      final f = RealOutputFixture()..hdrAvailable = true;
      final before = Map.of(f.options);
      expect(await f.apply(), true);
      expect(f.options['target-trc'], 'pq');
      expect(f.options['target-prim'], 'bt.2020');
      expect(await f.apply(token: 0), false);
      expect(f.options, before);
      expect(
        f.writes.any(
          (w) =>
              w.$1.contains('colormatrix') ||
              w.$1 == 'gamma' ||
              w.$1 == 'brightness',
        ),
        false,
      );
    },
  );
  test('captured advancing audio with no configured output is caught', () {
    final guard = VideoOutputLossWatch()..reset(expectedVideo: true);
    expect(guard.sample(missing(0), outputMissing: true), false);
    expect(guard.sample(missing(2), outputMissing: true), false);
    expect(guard.sample(missing(4), outputMissing: true), false);
    expect(guard.sample(missing(6), outputMissing: true), true);
  });
  test(
    'unknown output properties are not a positive missing-output report',
    () {
      final guard = VideoOutputLossWatch()..reset(expectedVideo: true);
      for (var n = 0; n <= 20; n += 2) {
        expect(guard.sample(missing(n), outputMissing: false), false);
      }
    },
  );
  test('pause buffering and seeks reset the absent-output observation', () {
    for (final state in ['pause', 'buffer', 'seek']) {
      final guard = VideoOutputLossWatch()..reset(expectedVideo: true);
      guard.sample(missing(0), outputMissing: true);
      guard.sample(missing(2), outputMissing: true);
      expect(
        guard.sample(
          missing(
            4,
            playing: state != 'pause',
            buffering: state == 'buffer',
            seeking: state == 'seek',
          ),
          outputMissing: true,
        ),
        false,
      );
      expect(guard.sample(missing(6), outputMissing: true), false);
      expect(guard.sample(missing(8), outputMissing: true), false);
    }
  });
  test('healthy output audio-only use and long sample gaps do not trigger', () {
    final guard = VideoOutputLossWatch();
    expect(guard.sample(missing(0), outputMissing: true), false);
    expect(guard.sample(missing(10), outputMissing: true), false);
    guard.reset(expectedVideo: true);
    guard.sample(missing(0), outputMissing: true);
    expect(guard.sample(missing(10), outputMissing: true), false);
    expect(guard.sample(missing(12, ready: true), outputMissing: false), false);
  });
}
