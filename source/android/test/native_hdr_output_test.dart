import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/native_hdr_output.dart';

class OutputHarness {
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
  String wid = '900', vo = 'gpu';
  String? ignore, brokenRestore, missingRead;
  bool unavailable = false;
  Future<String> read(String key) async {
    if (key == 'vid') return '1';
    if (key == 'vo-configured') {
      return vo == 'gpu' &&
              !(unavailable &&
                  options['gpu-context']!.startsWith('android-hdr'))
          ? 'yes'
          : 'no';
    }
    if (key == 'video-frame-info/interlaced') return vo == 'gpu' ? 'no' : '';
    if (key == 'options/vo') return vo;
    if (key == 'options/wid') return wid;
    if (key == missingRead) throw StateError('unavailable');
    if (key == 'current-vo') {
      return unavailable && options['gpu-context']!.startsWith('android-hdr')
          ? 'null'
          : vo;
    }
    return options[key.replaceFirst('options/', '')] ?? '';
  }

  Future<void> write(String key, String value) async {
    writes.add((key, value));
    if (key == ignore && value != 'bt.1886') return;
    if (key == brokenRestore && value == 'bt.1886') {
      throw StateError('restore refused');
    }
    if (key == 'vo') {
      vo = value;
    } else if (key == 'wid') {
      wid = value;
    } else if (options.containsKey(key)) {
      options[key] = value;
    }
  }

  Future<bool> apply({
    int token = 7,
    String transfer = 'pq',
    int width = 1920,
    bool fill = false,
    bool keepPanscan = false,
  }) => output.apply(
    surface: token,
    width: width,
    height: 1080,
    transfer: transfer,
    fill: fill,
    keepPanscan: keepPanscan,
    textureSurface: 900,
    textureWidth: 1920,
    textureHeight: 1080,
    originalOutput: 'gpu',
    read: read,
    write: write,
  );
}

void main() {
  for (final transfer in ['pq', 'hlg']) {
    test(
      'native $transfer has no invented display peak and restores a previous numeric target',
      () async {
        final h = OutputHarness()..options['target-peak'] = '750';
        expect(await h.apply(transfer: transfer), isTrue);
        expect(h.options['target-peak'], 'auto');
        expect(h.options['target-trc'], transfer);
        expect(h.options['target-prim'], 'bt.2020');
        await h.apply(token: 0);
        expect(h.options['target-peak'], '750');
        expect(h.options['target-trc'], 'bt.1886');
      },
    );
  }
  test(
    'HDR transaction restores every option and texture without playback commands',
    () async {
      final h = OutputHarness();
      final before = Map<String, String>.of(h.options);
      expect(await h.apply(), isTrue);
      expect(h.options['target-trc'], 'pq');
      expect(h.wid, '7');
      expect(h.output.active, isTrue);
      await h.apply(token: 0);
      expect(h.options, before);
      expect(h.wid, '900');
      expect(h.vo, 'gpu');
      expect(h.output.active, isFalse);
      expect(
        h.writes.any(
          (x) => const {
            'pause',
            'seek',
            'speed',
            'aid',
            'sid',
            'volume',
            'hwdec',
          }.contains(x.$1),
        ),
        isFalse,
      );
    },
  );
  test(
    'unsupported EGL output restores compatibility and does not claim HDR',
    () async {
      final h = OutputHarness()..unavailable = true;
      final before = Map.of(h.options);
      expect(await h.apply(), isFalse);
      expect(h.options, before);
      expect(h.vo, 'gpu');
      expect(h.output.active, isFalse);
      expect(h.output.token, 0);
    },
  );
  test('a rejected named transfer is caught by actual readback', () async {
    final h = OutputHarness()..ignore = 'target-trc';
    final before = Map.of(h.options);
    expect(await h.apply(), isFalse);
    expect(h.options, before);
    expect(h.wid, '900');
    expect(h.writes.where((x) => x.$1 == 'vo' && x.$2 == 'gpu'), hasLength(1));
  });
  test('missing snapshot makes no mutation', () async {
    final h = OutputHarness()..missingRead = 'options/target-peak';
    expect(await h.apply(), isFalse);
    expect(h.writes, isEmpty);
    expect(h.output.active, isFalse);
  });
  test(
    'restore failure attempts later fields, retains pending state and surfaces failure',
    () async {
      final h = OutputHarness();
      await h.apply();
      h.brokenRestore = 'target-trc';
      await expectLater(h.apply(token: 0), throwsStateError);
      expect(h.output.active, isTrue);
      expect(h.writes.last, ('panscan', '0'));
      expect(h.vo, 'null');
      expect(h.wid, '0');
      h.brokenRestore = null;
      await h.apply(token: 0);
      expect(h.output.active, isFalse);
    },
  );
  test(
    'same Surface resize keeps context and all track/subtitle options',
    () async {
      final h = OutputHarness();
      await h.apply();
      h.writes.clear();
      expect(await h.apply(width: 2560, fill: true), isTrue);
      expect(h.writes, [
        ('android-surface-size', '2560x1080'),
        ('panscan', '1'),
      ]);
      await h.apply(token: 0);
      expect(h.options['panscan'], '0');
    },
  );
  test('phone fit remains owned by the existing adapter', () async {
    final h = OutputHarness();
    h.options['panscan'] = '0.35';
    expect(await h.apply(keepPanscan: true), isTrue);
    expect(h.options['panscan'], '0.35');
    h.options['panscan'] = '1';
    await h.apply(width: 2560, keepPanscan: true);
    await h.apply(token: 0);
    expect(h.options['panscan'], '1');
    expect(h.writes.any((x) => x.$1 == 'panscan'), isFalse);
  });
  test('invalid mode or size makes no native request', () async {
    final h = OutputHarness();
    expect(await h.apply(transfer: 'dolby'), isFalse);
    expect(await h.apply(width: 1), isFalse);
    expect(await h.apply(width: 20000), isFalse);
    expect(h.writes, isEmpty);
  });
  test(
    'HLG selects its own context and cannot reuse an unrelated live Surface',
    () async {
      final h = OutputHarness();
      expect(await h.apply(transfer: 'hlg'), isTrue);
      expect(h.options['gpu-context'], 'android-hdr-hlg');
      await expectLater(h.apply(token: 8), throwsStateError);
      await h.apply(token: 0);
    },
  );
}
