import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/surface_update.dart';
import 'package:yingyu/playback/audio_decode_watch.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'package:yingyu/playback/startup_seek.dart';
import 'runtime_health_test.dart' show sample;

void main() {
  for (final wid in [0, 123]) {
    test('surface without old frame never seeks, wid=$wid', () async {
      final writes = <String>[];
      final seeks = <Duration>[];
      await updateAndroidSurface(
        wid: wid,
        width: 3840,
        height: 2160,
        output: 'gpu',
        read: (_) async => 'unavailable',
        write: (k, v) async => writes.add('$k=$v'),
        seek: (p) async => seeks.add(p),
      );
      expect(writes, [
        'vo=null',
        'android-surface-size=3840x2160',
        'wid=$wid',
        'vo=${wid == 0 ? 'null' : 'gpu'}',
      ]);
      expect(seeks, isEmpty);
    });
  }
  for (final mode in [
    'ready',
    'seeking',
    'idle',
    'missing-clock',
    'zero',
    'embedded',
  ]) {
    test(
      'surface replacement preserves native resume and lifecycle $mode',
      () async {
        final seeks = <Duration>[];
        final writes = <String>[];
        final values = <String, String>{
          'video-frame-info/interlaced': 'no',
          'seeking': mode == 'seeking' ? 'yes' : 'no',
          'idle-active': mode == 'idle' ? 'yes' : 'no',
          'time-pos': mode == 'missing-clock'
              ? 'unavailable'
              : mode == 'zero'
              ? '0'
              : '597.322',
        };
        await updateAndroidSurface(
          wid: 123,
          width: 3840,
          height: 2160,
          output: mode == 'embedded' ? 'mediacodec_embed' : 'gpu',
          read: (k) async => values[k]!,
          write: (k, v) async => writes.add('$k=$v'),
          seek: (p) async => seeks.add(p),
        );
        expect(seeks, switch (mode) {
          'ready' || 'embedded' => [const Duration(milliseconds: 597322)],
          'zero' => [Duration.zero],
          _ => isEmpty,
        });
        if (mode == 'embedded') expect(writes.last, 'vid=auto');
      },
    );
  }
  test(
    'initial exact seek option restores original after output or cancellation',
    () async {
      final values = {'hr-seek-framedrop': 'no', 'vf': '', 'deinterlace': 'no'};
      final setup = StartupSeekSetup();
      Future<String> read(String k) async => values[k]!;
      Future<void> write(String k, String v) async {
        values[k] = v;
      }

      expect(await setup.prepare(read: read, write: write), true);
      expect(values['hr-seek-framedrop'], 'yes');
      expect(await setup.prepare(read: read, write: write), false);
      await setup.restore(read: read, write: write);
      expect(values['hr-seek-framedrop'], 'no');
    },
  );
  for (final kind in ['filter', 'deinterlace', 'already-enabled']) {
    test(
      'initial seek preserves explicitly incompatible state $kind',
      () async {
        final values = {
          'hr-seek-framedrop': kind == 'already-enabled' ? 'yes' : 'no',
          'vf': kind == 'filter' ? 'yadif' : '',
          'deinterlace': kind == 'deinterlace' ? 'yes' : 'no',
        };
        final writes = <String>[];
        expect(
          await StartupSeekSetup().prepare(
            read: (k) async => values[k]!,
            write: (k, v) async => writes.add(k),
          ),
          false,
        );
        expect(writes, isEmpty);
      },
    );
  }
  test(
    'rejected startup seek option rolls back and cannot silently leak',
    () async {
      var value = 'no';
      final writes = <String>[];
      final setup = StartupSeekSetup();
      expect(
        await setup.prepare(
          read: (k) async => k == 'vf'
              ? ''
              : k == 'deinterlace'
              ? 'no'
              : value,
          write: (k, v) async {
            writes.add(v);
            if (v == 'no') value = v;
          },
        ),
        false,
      );
      expect(writes, ['yes', 'no']);
    },
  );
  for (final speed in [1.0, 2.0, 3.0]) {
    test(
      'stationary video with advancing audio earns one recovery at $speed',
      () {
        final watch = RuntimeHealthWatch();
        watch.sample(sample(0, 0, 8), speed: speed);
        expect(
          watch.sample(sample(6, 0, 14), speed: speed),
          RuntimeAction.recover,
        );
        final hw = speed > 2 ? 'no' : 'mediacodec-copy';
        watch.beginRecovery(
          const Duration(seconds: 5),
          const Duration(seconds: 6),
          hardware: hw,
        );
        watch.sample(sample(8, 5, 5, hardware: hw), speed: speed);
        expect(
          watch.sample(sample(10, 7, 7, hardware: hw), speed: speed),
          RuntimeAction.recovered,
        );
        expect(
          watch.sample(sample(16, 7, 13, hardware: hw), speed: speed),
          RuntimeAction.fail,
        );
      },
    );
  }
  test('only the exact pinned audio packet error is recoverable', () {
    expect(isAudioPacketError('ad', 'error', 'Error decoding audio.\n'), true);
    for (final p in ['vd', 'ffmpeg', 'cplayer']) {
      expect(isAudioPacketError(p, 'error', 'Error decoding audio.'), false);
    }
    expect(
      isAudioPacketError('ad', 'error', 'Failed to initialize audio decoder'),
      false,
    );
  });
  test(
    'audio error requires fresh audio AND video, keeps the fault until verified',
    () {
      final watch = AudioDecodeWatch()..fault(Duration.zero, playing: true);
      expect(watch.sample(sample(1, 10, 10)), AudioDecodeAction.none);
      expect(watch.sample(sample(2, 11, 10)), AudioDecodeAction.none);
      expect(watch.sample(sample(3, 12, 12)), AudioDecodeAction.verified);
      expect(watch.pending, false);
    },
  );
  test(
    'audio errors cannot repeatedly extend deadline or hide a silent track',
    () {
      final watch = AudioDecodeWatch()..fault(Duration.zero, playing: true);
      watch.sample(sample(2, 10, 10));
      watch.fault(const Duration(seconds: 4), playing: true);
      expect(watch.sample(sample(8, 16, 10)), AudioDecodeAction.fail);
      watch.fault(const Duration(seconds: 10), playing: false);
      for (var i = 0; i < 7; i++) {
        watch.fault(const Duration(seconds: 10), playing: false);
      }
      expect(
        watch.sample(sample(10, 0, 0, playing: false)),
        AudioDecodeAction.fail,
      );
    },
  );
  test(
    'pause opening and user track change do not falsely pass or age audio recovery',
    () {
      final watch = AudioDecodeWatch()..fault(Duration.zero, playing: false);
      expect(
        watch.sample(sample(30, 0, 0, playing: false)),
        AudioDecodeAction.none,
      );
      watch.sample(sample(32, 0, 0));
      watch.sample(sample(34, 1, 1, buffering: true));
      expect(watch.sample(sample(35, 1, 1)), AudioDecodeAction.none);
      expect(watch.sample(sample(36, 2, 2)), AudioDecodeAction.verified);
      watch.fault(const Duration(seconds: 40), playing: true);
      watch.cancel();
      expect(watch.sample(sample(50, 2, 2)), AudioDecodeAction.none);
    },
  );
}
