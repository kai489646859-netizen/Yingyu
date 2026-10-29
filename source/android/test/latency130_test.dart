import 'dart:async';
import 'dart:convert';
import 'host/opening128/current.dart' as current;
import 'host/opening128/old.dart' as old;
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/latency_probe.dart';

class Io {
  Io({this.limit = const Duration(seconds: 2)});
  final Duration limit;
  final rows = <String>[], writes = <String>[], levels = <String>[];
  final values = <String, String>{
    'options/msg-level': 'all=warn,custom=error',
    'time-pos': '1119.214',
    'audio-pts': '1119.214',
    'aid': '1',
    'seeking': 'no',
    'paused-for-cache': 'no',
    'vo-configured': 'yes',
    'video-frame-info/interlaced': 'no',
    'demuxer-cache-state':
        '{"fw-bytes":64,"seekable-ranges":[{"start":1129.854,"end":1156.822}]}',
  };
  Future<String> Function(String)? beforeRead;
  Future<void> Function(String, String)? beforeWrite;
  int reads = 0;
  Future<String> read(String k) async {
    reads++;
    return await beforeRead?.call(k) ?? values[k] ?? '';
  }

  Future<void> write(String k, String v) async {
    await beforeWrite?.call(k, v);
    writes.add('$k=$v');
    values['options/$k'] = v;
  }

  late final probe = PlaybackLatencyProbe(
    read: read,
    write: write,
    request: (s) {
      levels.add(s);
      return 0;
    },
    record: rows.add,
    interval: const Duration(milliseconds: 10),
    limit: limit,
  );
  void start({bool producer = true, String phase = 'seek'}) => probe.begin(
    phase: phase,
    target: const Duration(milliseconds: 1119214),
    producer: producer,
  );
}

Future<void> tick([int ms = 20]) =>
    Future<void>.delayed(Duration(milliseconds: ms));
void main() {
  test(
    'old output arriving before the native seek cannot narrow new seek diagnostics',
    () async {
      final io = Io();
      io.start();
      await tick();
      io.probe.add(
        'ffmpeg/video',
        'hevc_mediacodec: Got output buffer 0 offset=0 size=800 ts=6933927000 flags=0',
      );
      await tick();
      expect(io.rows.any((r) => r.contains('first_codec_output')), false);
      io.probe.nativeEvent(seek: true, restart: false);
      io.probe.add(
        'ffmpeg/video',
        'hevc_mediacodec: Got output buffer 0 offset=0 size=800 ts=171036000 flags=0',
      );
      await tick();
      expect(io.rows.where((r) => r.contains('first_codec_output')).length, 1);
      expect(
        io.rows.lastWhere((r) => r.contains('first_codec_output')),
        contains('171036000'),
      );
      await io.probe.close();
    },
  );

  for (final legacy in [false, true]) {
    test(
      'full seek path adds diagnostics without changing exact target, legacy=$legacy',
      () async {
        final dynamic h = legacy ? old.Harness() : current.Harness();
        final io = Io();
        h.latency = io.probe;
        await h.seek(const Duration(milliseconds: 1119214));
        await tick();
        expect(h.player.seeks, [const Duration(milliseconds: 1119214)]);
        expect(h.player.playCalls, 0);
        expect(h.player.openCalls, 0);
        expect(
          io.rows.any((r) => r.contains('phase=seek') && r.contains('begin')),
          !legacy,
        );
        await io.probe.close();
        expect(io.writes, isEmpty);
      },
    );
  }

  test('forward cache is not proof of a backward target cache hit', () {
    expect(
      PlaybackLatencyProbe.cacheFacts(
        '{"fw-bytes":64,"seekable-ranges":[{"start":1129.854,"end":1156.822}]}',
        1119.214,
      ),
      {'fw-bytes': 64, 'ranges': 1, 'target-in-range': false},
    );
    expect(
      PlaybackLatencyProbe.cacheFacts(
        '{"seekable-ranges":[{"start":1110,"end":1130}]}',
        1119.214,
      )['target-in-range'],
      true,
    );
  });
  test(
    'cache observations whitelist numeric values and reject malformed ranges',
    () {
      final f = PlaybackLatencyProbe.cacheFacts(
        jsonEncode({
          'reader-pts': 2,
          'raw-input-rate': 'https://secret/token',
          'fw-bytes': 10,
          'private': 'TOKEN',
          'seekable-ranges': [
            {'start': 3, 'end': 1},
          ],
        }),
        2,
      );
      expect(f, {'reader-pts': 2, 'fw-bytes': 10});
      expect(PlaybackLatencyProbe.cacheFacts('invalid TOKEN', 2), isEmpty);
      expect(
        PlaybackLatencyProbe.cacheFacts(
          '{"seekable-ranges":[]}',
          2,
        )['target-in-range'],
        false,
      );
    },
  );
  test(
    'a reply or cache=false cannot announce recovery while seeking',
    () async {
      final io = Io();
      io.values['seeking'] = 'yes';
      io.values['audio-pts'] = '';
      io.start();
      await tick();
      io.probe.nativeEvent(seek: true, restart: false);
      io.probe.nativeEvent(seek: false, restart: true);
      await tick();
      expect(
        io.rows.any((r) => r.contains('target_near_output_sample')),
        false,
      );
      expect(io.rows.any((r) => r.contains('seeking=true')), true);
      io.values['seeking'] = 'no';
      io.values['audio-pts'] = '1119.214';
      await tick();
      expect(
        io.rows.where((r) => r.contains('target_near_output_sample')).length,
        1,
      );
      await io.probe.close();
      expect(io.values['options/msg-level'], 'all=warn,custom=error');
    },
  );
  test(
    'restart before any seek and frame without audio do not complete',
    () async {
      final io = Io();
      io.start();
      io.probe.nativeEvent(seek: false, restart: true);
      await tick();
      expect(io.rows.any((r) => r.contains('observed_output')), false);
      io.values['audio-pts'] = '';
      io.probe.nativeEvent(seek: true, restart: true);
      await tick();
      expect(io.rows.any((r) => r.contains('observed_output')), false);
      io.values['aid'] = 'no';
      await tick();
      expect(io.rows.any((r) => r.contains('observed_output')), true);
      await io.probe.close();
    },
  );
  test(
    'native milestones are numeric, once per stage; producer narrows after output',
    () async {
      final io = Io();
      io.start();
      await tick();
      io.probe.nativeEvent(seek: true, restart: false);
      for (var i = 0; i < 2; i++) {
        io.probe.add(
          'demux/lavf',
          'append packet to video: size=800 pts=1109.2 dts=1109.1 pos=123 [num=1 size=800]',
        );
        io.probe.add(
          'ffmpeg/video',
          'hevc_mediacodec: Queued input buffer 0 size=800 ts=1109200000',
        );
        io.probe.add(
          'ffmpeg/video',
          'hevc_mediacodec: Got output buffer 0 offset=0 size=800 ts=1109200000 flags=0',
        );
      }
      io.probe.add(
        'ffmpeg/video',
        'hevc_mediacodec: Queued input buffer 0 size=800 ts=1 TOKEN',
      );
      io.probe.add(
        'demux/lavf',
        'append packet to video: size=800 pts=1 dts=1 pos=1 [num=1 size=800]\nTOKEN',
      );
      await tick();
      expect(io.rows.where((r) => r.contains('first_demux_video')).length, 1);
      expect(io.rows.where((r) => r.contains('first_codec_output')).length, 1);
      expect(io.rows.join(), isNot(contains('TOKEN')));
      expect(io.writes.last, contains('ffmpeg/video=warn'));
      await io.probe.close();
      expect(io.levels.last, 'warn');
    },
  );
  test('event cap stops native producer while sampling continues', () async {
    final io = Io();
    io.start();
    await tick();
    for (var i = 0; i < 700; i++) {
      io.probe.add('other', 'TOKEN');
    }
    await tick();
    expect(io.levels.last, 'warn');
    expect(
      io.rows.where((r) => r.contains('producer_budget_exhausted')).length,
      1,
    );
    expect(io.rows.join(), isNot(contains('TOKEN')));
    await io.probe.close();
  });
  test(
    'rapid owners serialize exact log restoration and cannot publish stale reads',
    () async {
      final io = Io();
      final pending = Completer<String>();
      io.beforeRead = (k) async =>
          k == 'time-pos' ? pending.future : io.values[k] ?? '';
      io.start();
      await tick();
      io.start(phase: 'hdr_refill');
      await tick();
      pending.complete('1119.214');
      await tick();
      final second = io.rows.indexWhere(
        (r) => r.contains('id=2') && r.contains('begin'),
      );
      expect(
        io.rows
            .skip(second + 1)
            .any((r) => r.contains('id=1') && r.contains('sample')),
        false,
      );
      await io.probe.close();
      expect(io.values['options/msg-level'], 'all=warn,custom=error');
    },
  );
  test(
    'closing during producer setup prevents late enabling and restores saved rules',
    () async {
      final io = Io();
      final writing = Completer<void>();
      io.beforeWrite = (k, v) async {
        if (v.contains('demux=trace')) await writing.future;
      };
      io.start();
      await tick();
      final close = io.probe.close();
      writing.complete();
      await close;
      expect(io.levels, ['warn']);
      expect(io.values['options/msg-level'], 'all=warn,custom=error');
      expect(io.rows.any((r) => r.contains('producer_start')), false);
    },
  );
  test(
    'disabled producer for disc avoids touching another diagnostic owner',
    () async {
      final io = Io();
      io.start(producer: false);
      await tick();
      await io.probe.close();
      expect(io.writes, isEmpty);
      expect(io.levels, isEmpty);
      expect(io.rows.any((r) => r.contains('sample')), true);
    },
  );
  test(
    'deadline cancels polling, reports uncertainty and restores native diagnostics',
    () async {
      final io = Io(limit: const Duration(milliseconds: 80));
      io.start();
      await tick(140);
      final count = io.reads;
      await tick();
      expect(io.reads, count);
      expect(io.rows.any((r) => r.contains('reason=deadline')), true);
      expect(
        io.rows.any((r) => r.contains('missing_event_is_not_absence=true')),
        true,
      );
      await io.probe.close();
      expect(io.values['options/msg-level'], 'all=warn,custom=error');
    },
  );
}
