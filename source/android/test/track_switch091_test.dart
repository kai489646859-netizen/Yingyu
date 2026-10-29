import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/audio_track_switch.dart';
import 'package:yingyu/playback/audio_decode_watch.dart';
import 'package:yingyu/playback/subtitle_switch.dart';
import 'runtime_health_test.dart' show sample;

class Source {
  String aid = '1';
  bool active = true,
      playing = true,
      primed = false,
      needsRefresh = false,
      cache = false,
      seek = false;
  bool reject = false,
      rejectSecond = false,
      mismatch = false,
      failRefresh = false;
  Set<String> bad = {};
  int errors = 0, refreshes = 0;
  final writes = <String>[];
  final clock = Stopwatch()..start();
  Future<String> read(String key) async {
    if (key == 'aid') return aid;
    if (key == 'audio-params/samplerate') {
      return bad.contains(aid) ? 'unknown' : '48000';
    }
    if (key == 'seeking') return seek ? 'yes' : 'no';
    if (key == 'paused-for-cache') return cache ? 'yes' : 'no';
    if (key == 'audio-pts' &&
        (bad.contains(aid) || needsRefresh && !primed || !playing)) {
      throw StateError('audio pts unavailable');
    }
    return (100 + clock.elapsedMilliseconds / 1000).toString();
  }

  Future<AudioSwitchResult> change({bool disc = true, String target = '2'}) =>
      switchAudioTrack(
        requested: target,
        disc: disc,
        read: read,
        select: (id) async {
          writes.add(id);
          aid = mismatch && id == target ? '1' : id;
          reject = rejectSecond && id == target;
        },
        refresh: () async {
          refreshes++;
          primed = true;
          errors = 0;
          if (failRefresh) throw StateError('refresh failed');
        },
        active: () => active,
        playing: () => playing,
        packetErrors: () => errors,
        decoderRejected: () => reject,
        initialWait: const Duration(milliseconds: 200),
        outputWait: const Duration(milliseconds: 250),
        wallLimit: const Duration(milliseconds: 450),
        interval: const Duration(milliseconds: 10),
      );
}

void main() {
  test('only fixed audio-chain init failures enter track rollback path', () {
    expect(
      isAudioTrackInitError(
        'cplayer',
        'error',
        'Error reinitializing audio.\n',
      ),
      true,
    );
    expect(
      isAudioTrackInitError(
        'cplayer',
        'error',
        'Could not open/initialize audio device -> no sound.',
      ),
      true,
    );
    expect(
      isAudioTrackInitError(
        'cplayer',
        'error',
        'Audio filter initialized failed!',
      ),
      true,
    );
    expect(isAudioTrackInitError('ad', 'error', 'Could not open codec.'), true);
    expect(isAudioTrackInitError('cplayer', 'error', 'Playback failed'), false);
    expect(
      isAudioTrackInitError('vd', 'error', 'Could not open codec.'),
      false,
    );
    expect(
      isAudioTrackInitError('stream', 'error', 'Error reinitializing audio.'),
      false,
    );
    expect(
      isAudioTrackInitError('cplayer', 'warn', 'Error reinitializing audio.'),
      false,
    );
  });
  test(
    'native deselection while ownership remains active restores old track',
    () async {
      var aid = '1', disabled = false;
      final selected = <String>[];
      final clock = Stopwatch()..start();
      await expectLater(
        switchAudioTrack(
          requested: '2',
          disc: true,
          read: (key) async {
            if (key == 'aid') return aid;
            if (aid == '2' && !disabled) {
              disabled = true;
              aid = 'no';
            }
            if (key == 'seeking' || key == 'paused-for-cache') return 'no';
            return (100 + clock.elapsedMilliseconds / 1000).toString();
          },
          select: (id) async {
            selected.add(id);
            aid = id;
          },
          refresh: () async {},
          active: () => true,
          playing: () => true,
          packetErrors: () => 0,
          outputWait: const Duration(milliseconds: 250),
          interval: const Duration(milliseconds: 10),
          wallLimit: const Duration(milliseconds: 450),
        ),
        throwsA(
          isA<AudioSwitchFailure>().having((e) => e.restored, 'restored', true),
        ),
      );
      expect(aid, '1');
      expect(selected, ['2', '1']);
    },
  );
  test(
    'disc switch refreshes current timeline and verifies real new audio',
    () async {
      final source = Source()..needsRefresh = true;
      expect(await source.change(), AudioSwitchResult.verified);
      expect(source.refreshes, 1);
      expect(source.writes, ['2']);
    },
  );
  test('healthy ordinary switch avoids unnecessary seek', () async {
    final source = Source();
    expect(await source.change(disc: false), AudioSwitchResult.verified);
    expect(source.refreshes, 0);
  });
  test('ordinary decoder priming failure gets only one refresh', () async {
    final source = Source()..needsRefresh = true;
    expect(await source.change(disc: false), AudioSwitchResult.verified);
    expect(source.refreshes, 1);
  });
  for (final paused in [false, true]) {
    test('unusable audio returns to original choice paused=$paused', () async {
      final source = Source()..bad = {'2'};
      if (paused) {
        source.playing = false;
        source.rejectSecond = true;
      }
      await expectLater(
        source.change(),
        throwsA(
          isA<AudioSwitchFailure>().having((e) => e.restored, 'restored', true),
        ),
      );
      expect(source.aid, '1');
      expect(source.writes, ['2', '1']);
      expect(source.playing, !paused);
      expect(source.refreshes, 2);
    });
  }
  test('both failed outputs remain a real failure', () async {
    final source = Source()..bad = {'1', '2'};
    await expectLater(
      source.change(),
      throwsA(
        isA<AudioSwitchFailure>().having((e) => e.restored, 'restored', false),
      ),
    );
    expect(source.writes, ['2', '1']);
    expect(source.refreshes, 2);
  });
  test(
    'paused switch never starts playback or claims advancing output',
    () async {
      final source = Source()..playing = false;
      expect(await source.change(), AudioSwitchResult.deferred);
      expect(source.playing, false);
      expect(source.refreshes, 1);
    },
  );
  test('same track and intentional off keep existing behavior', () async {
    final source = Source();
    expect(await source.change(target: '1'), AudioSwitchResult.unchanged);
    expect(source.writes, isEmpty);
    expect(source.refreshes, 0);
    expect(await source.change(target: 'no'), AudioSwitchResult.disabled);
    expect(source.refreshes, 0);
  });
  test(
    'auto resolves actual ID without changing a healthy same selection',
    () async {
      final source = Source()..mismatch = true;
      // A dedicated callback models MPV resolving auto to the existing ID.
      expect(
        await switchAudioTrack(
          requested: 'auto',
          disc: true,
          read: source.read,
          select: (_) async {},
          refresh: () async {
            fail('unexpected refresh');
          },
          active: () => true,
          playing: () => true,
          packetErrors: () => 0,
        ),
        AudioSwitchResult.unchanged,
      );
    },
  );
  test(
    'selection mismatch restores original choice and does not report success',
    () async {
      final source = Source()..mismatch = true;
      await expectLater(
        source.change(),
        throwsA(
          isA<AudioSwitchFailure>().having((e) => e.restored, 'restored', true),
        ),
      );
      expect(source.aid, '1');
    },
  );
  test('refresh command failure is not silently accepted', () async {
    final source = Source()..failRefresh = true;
    await expectLater(
      source.change(),
      throwsA(
        isA<AudioSwitchFailure>().having((e) => e.restored, 'restored', false),
      ),
    );
    expect(source.refreshes, 2);
  });
  test(
    'new load/exit cancels without restoring into unrelated media',
    () async {
      final source = Source();
      Timer(const Duration(milliseconds: 20), () => source.active = false);
      await expectLater(source.change(), throwsA(isA<AudioSwitchCancelled>()));
      expect(source.writes, ['2']);
      expect(source.refreshes, 1);
    },
  );
  test(
    'buffered unknown audio has a wall limit and cannot be called verified',
    () async {
      final source = Source()
        ..cache = true
        ..bad = {'1', '2'};
      await expectLater(source.change(), throwsA(isA<AudioSwitchFailure>()));
      expect(source.refreshes, 2);
    },
  );
  test('eight genuine faults are delegated only during a bounded switch', () {
    final watch = AudioDecodeWatch()..holdForTrackSwitch(true);
    for (var i = 0; i < 8; i++) {
      watch.fault(Duration(seconds: i), playing: true);
    }
    expect(watch.errors, 8);
    expect(watch.trackSwitchHeld, true);
    expect(watch.sample(sample(10, 10, 0)), AudioDecodeAction.none);
    watch.holdForTrackSwitch(false);
    expect(watch.sample(sample(11, 11, 0)), AudioDecodeAction.fail);
  });
  test(
    'decoder rejection is scoped to current switch and cleared by real reset',
    () {
      final watch = AudioDecodeWatch();
      watch.rejectTrackSwitch();
      expect(watch.trackSwitchRejected, false);
      watch.holdForTrackSwitch(true);
      watch.rejectTrackSwitch();
      expect(watch.trackSwitchRejected, true);
      expect(watch.errors, 0);
      watch.cancel();
      expect(watch.trackSwitchRejected, false);
      watch.holdForTrackSwitch(false);
    },
  );
  for (final initial in ['no', '4']) {
    test(
      'subtitle partial failure restores selection AND renderer from $initial',
      () async {
        final values = {
          'sid': initial,
          'sub-visibility': initial == 'no' ? 'no' : 'yes',
        };
        final before = Map.of(values);
        final restored = <String>[];
        await expectLater(
          protectSubtitleSwitch(
            read: (k) async => values[k]!,
            restore: (k, v) async {
              restored.add(k);
              values[k] = v;
            },
            apply: () async {
              values['sid'] = '8';
              values['sub-visibility'] = 'no';
              throw StateError('display readback failed');
            },
            active: () => true,
          ),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.toString(),
              'message',
              contains('已恢复原字幕'),
            ),
          ),
        );
        expect(values, before);
        expect(restored, ['sid', 'sub-visibility']);
      },
    );
  }
  test('subtitle successful selection needs no restore', () async {
    final values = {'sid': '4', 'sub-visibility': 'yes'};
    await protectSubtitleSwitch(
      read: (k) async => values[k]!,
      restore: (_, _) async {
        fail('unexpected rollback');
      },
      apply: () async {
        values['sid'] = 'no';
        values['sub-visibility'] = 'no';
      },
      active: () => true,
    );
    expect(values['sid'], 'no');
    expect(values['sub-visibility'], 'no');
  });
  test(
    'subtitle rollback still attempts renderer if restoring track fails',
    () async {
      final values = {'sid': '4', 'sub-visibility': 'yes'};
      final restored = <String>[];
      await expectLater(
        protectSubtitleSwitch(
          read: (k) async => values[k]!,
          restore: (k, v) async {
            restored.add(k);
            if (k == 'sid') throw StateError('failed');
            values[k] = v;
          },
          apply: () async {
            values['sid'] = '8';
            values['sub-visibility'] = 'no';
            throw StateError('failed');
          },
          active: () => true,
        ),
        throwsA(
          isA<AppFailure>().having(
            (e) => e.toString(),
            'message',
            contains('未能完整恢复'),
          ),
        ),
      );
      expect(restored, ['sid', 'sub-visibility']);
      expect(values['sub-visibility'], 'yes');
    },
  );
  test(
    'late subtitle failure cannot write old settings into a new load',
    () async {
      var active = true;
      final writes = <String>[];
      await expectLater(
        protectSubtitleSwitch(
          read: (k) async => k == 'sid' ? '4' : 'yes',
          restore: (k, _) async {
            writes.add(k);
          },
          apply: () async {
            active = false;
            throw StateError('old load');
          },
          active: () => active,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(writes, isEmpty);
    },
  );
}
