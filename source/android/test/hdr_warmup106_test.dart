import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/native_hdr_output.dart';

class WarmupFixture {
  WarmupFixture({void Function(String, String)? onProgress}) {
    output = NativeHdrOutput(
      wait: wait,
      onProgress: onProgress,
      refresh: refresh,
      current: () => current,
    );
  }
  late final NativeHdrOutput output;
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
    'vo': 'gpu',
    'wid': '900',
  };
  final writes = <(String, String)>[];
  int elapsed = 0, refills = 0, hdrWaits = 0, restoreWaits = 0;
  int readyAfter = 3600;
  int? cancelAfter;
  int? closeAfter;
  bool current = true, configured = true, seeking = false;
  bool pendingSeek = true, known = true, restoreWorks = true;
  bool get hdr => options['gpu-context']!.startsWith('android-hdr');
  bool get ready => !hdr ? restoreWorks : elapsed >= readyAfter;
  Future<void> wait(Duration duration) async {
    elapsed += duration.inMilliseconds;
    if (hdr) {
      hdrWaits++;
    } else {
      restoreWaits++;
    }
    if (cancelAfter != null && elapsed >= cancelAfter!) current = false;
    if (closeAfter != null && elapsed >= closeAfter!) output.cancelForClose();
  }

  Future<String> read(String key) async {
    if (key.startsWith('options/')) return options[key.substring(8)] ?? '';
    final pending = seeking && !ready;
    return {
          'current-vo': options['vo']!,
          'vid': '1',
          'time-pos': '1999.998',
          'vo-configured': configured || ready
              ? 'yes'
              : known
              ? 'no'
              : '',
          'video-frame-info/interlaced': configured || ready ? 'no' : '',
          'seeking': pending ? (pendingSeek ? 'yes' : 'no') : 'no',
          'idle-active': 'no',
          'seekable': 'yes',
        }[key] ??
        '';
  }

  Future<void> write(String key, String value) async {
    writes.add((key, value));
    options[key] = value;
    if (key == 'vo') {
      configured = false;
      seeking = true;
    }
  }

  Future<void> refresh(String position) async {
    expect(position, '1999.998');
    elapsed = 0;
    refills++;
  }

  Future<bool> apply() => output.apply(
    surface: 7,
    width: 3840,
    height: 2512,
    transfer: 'pq',
    fill: false,
    textureSurface: 900,
    textureWidth: 3840,
    textureHeight: 2512,
    originalOutput: 'gpu',
    read: read,
    write: write,
  );
}

void main() {
  test(
    'closing during warmup detaches without rebuilding compatible video',
    () async {
      final f = WarmupFixture()
        ..readyAfter = 999999
        ..closeAfter = 200;
      expect(await f.apply(), false);
      expect(f.hdrWaits, lessThan(12));
      expect(f.options['wid'], '0');
      expect(f.refills, 1);
      expect(f.writes.where((e) => e == ('vo', 'gpu')).length, 1);
      expect(f.output.active, false);
      expect(f.output.status, 'closed-detached');
    },
  );
  test('a ready HDR output does not wait for the warmup deadline', () async {
    final f = WarmupFixture()..readyAfter = 0;
    expect(await f.apply(), true);
    expect(f.hdrWaits, 1);
    expect(f.refills, 1);
  });
  for (final seekPending in [true, false]) {
    test(
      'selected HDR decoder can configure after 3 seconds; seekPending=$seekPending',
      () async {
        final f = WarmupFixture()..pendingSeek = seekPending;
        expect(
          await f.apply(),
          true,
          reason:
              'An in-progress HDR decoder must not be discarded at the generic 3-second limit',
        );
        expect(f.options['wid'], '7');
        expect(f.options['target-trc'], 'pq');
        expect(f.output.mode, 'pq');
        expect(f.refills, 1);
        expect(
          f.writes.where(
            (e) => const {'aid', 'sid', 'pause', 'loadfile'}.contains(e.$1),
          ),
          isEmpty,
        );
      },
    );
  }
  test(
    'unavailable native facts do not gain the extended HDR warmup',
    () async {
      final f = WarmupFixture()
        ..known = false
        ..pendingSeek = false
        ..readyAfter = 999999;
      expect(await f.apply(), false);
      expect(f.hdrWaits, lessThanOrEqualTo(120));
      expect(f.options['wid'], '900');
      expect(f.output.active, false);
    },
  );
  test(
    'a permanently pending HDR decoder remains bounded and restores SDR',
    () async {
      final f = WarmupFixture()..readyAfter = 999999;
      expect(await f.apply(), false);
      expect(f.hdrWaits, lessThanOrEqualTo(320));
      expect(f.refills, 2);
      expect(f.options['target-trc'], 'bt.1886');
      expect(f.options['wid'], '900');
      expect(f.output.active, false);
    },
  );
  test(
    'cancellation interrupts HDR warmup without waiting for its deadline',
    () async {
      final f = WarmupFixture()
        ..readyAfter = 999999
        ..cancelAfter = 200;
      expect(await f.apply(), false);
      expect(f.hdrWaits, lessThan(12));
    },
  );
  test(
    'HDR delay does not enlarge a failed compatible restoration deadline',
    () async {
      final f = WarmupFixture()
        ..readyAfter = 999999
        ..restoreWorks = false;
      await expectLater(f.apply(), throwsStateError);
      expect(f.restoreWaits, lessThanOrEqualTo(120));
      expect(f.output.active, true);
    },
  );
}
