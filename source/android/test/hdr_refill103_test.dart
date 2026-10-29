import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/native_hdr_output.dart';
import 'host/hdr103_old_output.dart' as old;
import 'host/recovery101_output_io.dart';
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';

// The pinned MPV VO option callback uninitializes the video chain and decoder.
// This seam models its emptied frame queue and a GOP requiring an exact refill.
// It does not simulate Android decoding, EGL pixels or screen acceptance.
class RefillFixture {
  RefillFixture({bool released = false}) {
    output = released
        ? old.NativeHdrOutput(wait: wait)
        : NativeHdrOutput(wait: wait, refresh: refresh, current: () => current);
  }
  late final dynamic output;
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
  final refreshes = <String>[];
  String position = '696.820000';
  String seeking = 'no', seekable = 'yes', actual = 'gpu';
  bool frame = true, selected = true, current = true;
  bool rejectHdr = false, rejectCompatible = false, loseSelection = false;
  bool cancelOnHdr = false, failRefresh = false;
  bool internalRestart = false;
  int pendingFrame = 0, waits = 0, frameDelay = 0;
  Future<void> wait(Duration _) async {
    waits++;
    if (pendingFrame > 0 && --pendingFrame == 0) frame = true;
  }

  Future<String> read(String key) async {
    if (key.startsWith('options/')) return options[key.substring(8)] ?? '';
    return {
          'current-vo': actual,
          'vo-configured': frame ? 'yes' : 'no',
          'video-frame-info/interlaced': frame ? 'no' : '',
          'vid': selected ? '1' : 'no',
          'time-pos': position,
          'seeking': seeking,
          'idle-active': 'no',
          'seekable': seekable,
        }[key] ??
        '';
  }

  Future<void> write(String key, String value) async {
    writes.add((key, value));
    if (options.containsKey(key)) options[key] = value;
    if (key == 'vid') selected = true;
    if (key == 'vo') {
      frame = false;
      if (value == 'gpu' && internalRestart) seeking = 'yes';
      final hdr = options['gpu-context']!.startsWith('android-hdr');
      actual = value == 'gpu' && (hdr ? rejectHdr : rejectCompatible)
          ? ''
          : value;
      if (value == 'gpu' && hdr && loseSelection) selected = false;
      if (value == 'gpu' && hdr && cancelOnHdr) current = false;
    }
  }

  Future<void> refresh(String value) async {
    if (failRefresh) throw StateError('refill refused');
    refreshes.add(value);
    position = value;
    seeking = 'no';
    if (actual == 'gpu' && selected) {
      pendingFrame = frameDelay;
      frame = pendingFrame == 0;
    }
  }

  Future<bool> apply({int token = 7}) async =>
      await output.apply(
            surface: token,
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
          )
          as bool;
}

void main() {
  test('internal restart seeking flag cannot suppress the required HDR refill', () async {
    final f = RefillFixture()..internalRestart = true;
    expect(await f.apply(), true);
    expect(f.refreshes, ['696.820000']);
    expect(f.frame, true);
  });
  test('actual user command path invalidates refreshes for seek, load and stop', () async {
    final io = OutputIo();
    for (final command in [
      ['seek', '800', 'absolute'], ['loadfile', 'synthetic-only'], ['stop'],
    ]) {
      final before = io.outputEpoch;
      await io.userCommand(command);
      expect(io.outputEpoch, before + 1);
    }
    await io.userCommand(['set', 'aid', '2']);
    expect(io.outputEpoch, 3);
  });
  test('native refresh deadline removes requests and ignores a late reply', () {
    fakeAsync((clock) {
      final io = OutputIo();
      io.mpv.deferred = true;
      var failures = 0;
      io.refreshOutputFrame('696.82', epoch: 0).then<void>((_) {},
          onError: (Object _) { failures++; });
      clock.elapse(const Duration(seconds: 4));
      clock.flushMicrotasks();
      expect(failures, 1);
      expect(io.pending, 0);
      io.mpv.flush();
      clock.flushMicrotasks();
      expect(failures, 1);
      expect(io.pending, 0);
    });
  });
  test(
    'complete released102 reproduces missing HDR frame and failed fallback',
    () async {
      final before = RefillFixture(released: true);
      await expectLater(before.apply(), throwsStateError);
      expect(before.output.status, 'restore-frame');
      expect(before.refreshes, isEmpty);
      expect(before.frame, false);
      final after = RefillFixture();
      expect(await after.apply(), true);
      expect(after.frame, true);
      expect(after.refreshes, ['696.820000']);
      expect(after.output.status, 'hdr-ready');
    },
  );
  test('real rejection recovers compatibility at the original frame', () async {
    final f = RefillFixture()..rejectHdr = true;
    final before = Map.of(f.options);
    expect(await f.apply(), false);
    expect(f.options, before);
    expect(f.frame, true);
    expect(f.refreshes, ['696.820000']);
    expect(f.output.active, false);
  });
  test('HDR renderer reselects only the lost original video', () async {
    final f = RefillFixture()..loseSelection = true;
    expect(await f.apply(), true);
    expect(f.writes.where((e) => e.$1 == 'vid'), [
      ('vid', '1'),
      ('vid', 'auto'),
    ]);
    expect(f.refreshes.length, 1);
  });
  test(
    'an acknowledged refresh without a frame remains a real failure',
    () async {
      final f = RefillFixture()
        ..rejectHdr = true
        ..rejectCompatible = true;
      await expectLater(f.apply(), throwsStateError);
      expect(f.output.active, true);
      expect(f.output.details, contains('configured=no'));
      expect(f.output.details, contains('frame=unavailable'));
    },
  );
  test(
    'cold decoder readiness returns immediately after two valid samples',
    () async {
      final f = RefillFixture()..frameDelay = 3;
      expect(await f.apply(), true);
      expect(f.waits, 4);
      expect(f.refreshes.length, 1);
    },
  );
  for (final invalid in ['', 'nan', '-1', 'Infinity', '1000000000']) {
    test(
      'unavailable position $invalid leaves the working picture untouched',
      () async {
        final f = RefillFixture()..position = invalid;
        expect(await f.apply(), false);
        expect(f.writes, isEmpty);
        expect(f.frame, true);
      },
    );
  }
  test('zero is a valid exact refresh position', () async {
    final f = RefillFixture()..position = '0';
    expect(await f.apply(), true);
    expect(f.refreshes, ['0']);
  });
  test('pending seek or nonseekable stream is not disturbed for HDR', () async {
    for (final f in [
      RefillFixture()..seeking = 'yes',
      RefillFixture()..seekable = 'no',
    ]) {
      expect(await f.apply(), false);
      expect(f.writes, isEmpty);
    }
  });
  test('newer media intent prevents an old-position refresh', () async {
    final f = RefillFixture()..cancelOnHdr = true;
    expect(await f.apply(), false);
    expect(f.refreshes, isEmpty);
    expect(f.options['target-trc'], 'bt.1886');
  });
  test('later fallback uses the current HDR frame position', () async {
    final f = RefillFixture();
    expect(await f.apply(), true);
    f.position = '712.250000';
    expect(await f.apply(token: 0), false);
    expect(f.refreshes, ['696.820000', '712.250000']);
    expect(f.frame, true);
  });
  test(
    'HDR retains source transform and decoder, audio, subtitles and pause',
    () async {
      final f = RefillFixture();
      expect(await f.apply(), true);
      expect(f.options['target-prim'], 'bt.2020');
      expect(f.options['target-trc'], 'pq');
      expect(f.options['dither-depth'], '10');
      expect(
        f.writes.where(
          (e) => const {
            'hwdec',
            'aid',
            'sid',
            'pause',
            'speed',
            'video-params/gamma',
            'video-params/colormatrix',
            'gamma',
            'brightness',
          }.contains(e.$1),
        ),
        isEmpty,
      );
    },
  );
  test(
    'close detaches without decoder refill or restoring a renderer',
    () async {
      final f = RefillFixture();
      expect(await f.apply(), true);
      f.writes.clear();
      await f.output.detachForClose(read: f.read, write: f.write);
      expect(f.writes, [('vo', 'null'), ('wid', '0')]);
      expect(f.refreshes.length, 1);
    },
  );
  test(
    '30 repeated opens, HDR rejections and closes retain no active ownership',
    () async {
      for (var i = 0; i < 30; i++) {
        final f = RefillFixture()..rejectHdr = i.isOdd;
        expect(await f.apply(), i.isEven);
        await f.output.detachForClose(read: f.read, write: f.write);
        expect(f.output.active, false);
      }
    },
  );
  test(
    'native refresh command is exact and acknowledged with no leaked request',
    () async {
      final io = OutputIo();
      await io.refreshOutputFrame('696.820000', epoch: 0);
      expect(io.mpv.commands, [
        ['seek', '696.820000', 'absolute+exact'],
      ]);
      expect(io.pending, 0);
      io.outputEpoch++;
      await expectLater(io.refreshOutputFrame('1', epoch: 0), throwsStateError);
      expect(io.mpv.commands.length, 1);
    },
  );
  test('native refresh refusal and negative reply remain failures', () async {
    for (final immediate in [true, false]) {
      final io = OutputIo();
      if (immediate) {
        io.mpv.result = -3;
      } else {
        io.mpv.error = -12;
      }
      await expectLater(io.refreshOutputFrame('0', epoch: 0), throwsStateError);
      expect(io.pending, 0);
    }
  });
  test('user seek during native refresh invalidates its late reply', () async {
    final io = OutputIo();
    io.mpv.deferred = true;
    final failed = expectLater(
      io.refreshOutputFrame('696.82', epoch: 0),
      throwsStateError,
    );
    io.outputEpoch++;
    await io.mpv.flush();
    await failed;
    expect(io.pending, 0);
  });
}
