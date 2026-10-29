import 'dart:async';
import 'dart:convert';

import 'opening_logs.dart';

/// Optional observation only. No media, cache, seek or decoder commands.
/// Every record belongs to one owner; a retired owner's IO cannot publish.
class PlaybackLatencyProbe {
  PlaybackLatencyProbe({
    required this.read,
    required this.write,
    required this.request,
    required this.record,
    this.interval = const Duration(seconds: 1),
    this.limit = const Duration(seconds: 25),
  });

  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final int Function(String) request;
  final void Function(String) record;
  final Duration interval, limit;
  Future<void> _tail = Future.value();
  _Window? _window;
  int _serial = 0;
  bool _disposed = false;
  static const _packetRules =
      'all=warn,demux=trace,mkv=trace,lavf=trace,ffmpeg=trace,ffmpeg/video=trace,'
      'ffmpeg/audio=warn,ffmpeg/demuxer=warn';
  static const _httpRules =
      'all=warn,ffmpeg=trace,ffmpeg/video=warn,'
      'ffmpeg/audio=warn,ffmpeg/demuxer=warn';

  /// Returns immediately. Diagnostics must never delay an actual seek/refill.
  void begin({
    required String phase,
    required Duration target,
    required bool producer,
    void Function(String, String)? http,
    void Function()? finishHttp,
  }) {
    if (_disposed) return;
    finish('superseded');
    final w = _Window(++_serial, phase, target, http, finishHttp);
    _window = w;
    _emit(w, 'begin target_ms=${target.inMilliseconds}; producer=$producer');
    w.deadline = Timer(limit, () => finish('deadline'));
    _tail = _tail.then((_) async {
      if (!_current(w)) return;
      if (producer) {
        final scope = OpeningLogs(
          read: read,
          write: write,
          request: request,
          duration: limit,
          rulesOverride: _packetRules,
        );
        w.scope = scope;
        await scope.start();
        if (!_current(w)) {
          await scope.close();
          return;
        }
        _emit(
          w,
          'producer_start enabled=${scope.enabled}; '
          'earlier_events=unknown; raw_body_bytes=unavailable',
        );
      }
      unawaited(_sample(w));
    });
  }

  bool _current(_Window w) => !_disposed && identical(_window, w);
  void _emit(_Window w, String fact) {
    if (_current(w)) {
      record(
        '[LAT130] id=${w.id} phase=${w.phase} '
        't_ms=${w.clock.elapsedMilliseconds}; $fact',
      );
    }
  }

  /// Actual native events, never a command's acknowledgement.
  void nativeEvent({required bool seek, required bool restart}) {
    final w = _window;
    if (w == null) return;
    if (seek) {
      w.seeks++;
      w.restart = false;
      _emit(w, 'native_seek count=${w.seeks}');
    }
    if (restart && w.seeks > 0) {
      w.restart = true;
      w.restartAt = w.clock.elapsedMilliseconds;
      _emit(w, 'native_restart');
    }
  }

  static final _packet = RegExp(
    r'^append packet to (video|audio): size=(\d{1,12}) '
    r'pts=(-?\d{1,22}(?:\.\d{1,9})?) dts=(-?\d{1,22}(?:\.\d{1,9})?) '
    r'pos=(-?\d{1,22}) \[num=(?:1|>1) size=\d+\]\s*$',
  );
  static final _input = RegExp(
    r'^Queued input buffer \d{1,8} size=(\d{1,12}) ts=(-?\d{1,22})\s*$',
  );
  static final _output = RegExp(
    r'^Got output buffer \d{1,8} offset=\d{1,12} size=(\d{1,12}) '
    r'ts=(-?\d{1,22}) flags=\d{1,12}\s*$',
  );

  void add(String prefix, String text) {
    final w = _window;
    if (w == null || w.scope?.enabled != true || w.events >= 600) return;
    w.events++;
    w.http?.call(prefix, text);
    final line = text.trim();
    if (w.seeks > 0 &&
        line.length <= 400 &&
        !line.contains('\n') &&
        !line.contains('\r')) {
      if (const {
        'demux/lavf',
        'demux/mkv',
        'mkv',
        'demux/edl',
        'demux/timeline',
        'lavf',
        'edl',
      }.contains(prefix)) {
        final m = _packet.firstMatch(line);
        if (m != null && w.first.add('packet_${m[1]}')) {
          _emit(
            w,
            'first_demux_${m[1]} bytes=${m[2]} pts_s=${m[3]}; '
            'not_http_first_byte=true',
          );
        }
      } else if (prefix == 'ffmpeg/video') {
        final value = line.replaceFirst(
          RegExp(r'^(?:hevc|h264|vp8|vp9|av1|mpeg2)_mediacodec: '),
          '',
        );
        final input = _input.firstMatch(value),
            output = _output.firstMatch(value);
        if (input != null && w.first.add('input')) {
          _emit(w, 'first_codec_input bytes=${input[1]} pts_us=${input[2]}');
        }
        if (output != null && w.first.add('output')) {
          _emit(w, 'first_codec_output bytes=${output[1]} pts_us=${output[2]}');
          _narrow(w);
        }
      }
    }
    // Stop packet traffic at its producer, not just its Dart parser.
    if (w.events == 600) {
      _emit(w, 'producer_budget_exhausted; subsequent_native_events=unknown');
      unawaited(w.scope?.close());
    }
  }

  void _narrow(_Window w) {
    _tail = _tail.then((_) async {
      if (_current(w)) await w.scope?.restrict(_httpRules);
    });
  }

  static double? _number(String? value) {
    final n = double.tryParse(value ?? '');
    return n != null && n.isFinite ? n : null;
  }

  /// Whitelist numeric cache facts. Unknown or hostile JSON never goes to logs.
  static Map<String, Object> cacheFacts(String text, double target) {
    final result = <String, Object>{};
    try {
      if (text.length > 65536) return result;
      final value = jsonDecode(text);
      if (value is! Map) return result;
      for (final key in const [
        'fw-bytes',
        'total-bytes',
        'reader-pts',
        'raw-input-rate',
      ]) {
        final n = value[key];
        if (n is num && n.isFinite) result[key] = n;
      }
      final ranges = value['seekable-ranges'];
      if (ranges is List) {
        var valid = true, contains = false;
        for (final r in ranges) {
          if (r is! Map || r['start'] is! num || r['end'] is! num) {
            valid = false;
            break;
          }
          final a = r['start'] as num, b = r['end'] as num;
          if (!a.isFinite || !b.isFinite || a > b) {
            valid = false;
            break;
          }
          if (a <= target && target <= b) contains = true;
        }
        if (valid) {
          result['ranges'] = ranges.length;
          result['target-in-range'] = contains;
        }
      }
    } catch (_) {
      /* Unsupported cache property is unknown. */
    }
    return result;
  }

  Future<void> _sample(_Window w) async {
    if (!_current(w)) return;
    final began = w.clock.elapsedMilliseconds;
    final beganAfterRestart = w.restart;
    final seekGeneration = w.seeks;
    const keys = [
      'time-pos',
      'audio-pts',
      'aid',
      'seeking',
      'paused-for-cache',
      'vo-configured',
      'video-frame-info/interlaced',
      'demuxer-cache-state',
    ];
    final values = await Future.wait(
      keys.map((key) async {
        try {
          return await read(key).timeout(const Duration(milliseconds: 600));
        } catch (_) {
          return '';
        }
      }),
    );
    if (!_current(w)) return;
    final v = Map.fromIterables(keys, values);
    final pos = _number(v['time-pos']), audio = _number(v['audio-pts']);
    bool? flag(String key) => switch (v[key]) {
      'yes' => true,
      'no' => false,
      _ => null,
    };
    final frame = const {
      'yes',
      'no',
    }.contains(v['video-frame-info/interlaced']);
    final cache = cacheFacts(
      v['demuxer-cache-state'] ?? '',
      w.target.inMicroseconds / 1e6,
    );
    _emit(
      w,
      'sample span_ms=${w.clock.elapsedMilliseconds - began}; '
      'position_s=$pos audio_s=$audio seeking=${flag('seeking')} '
      'cache_pause=${flag('paused-for-cache')} '
      'vo=${flag('vo-configured')} frame=$frame; cache=${jsonEncode(cache)}; '
      'sequential_properties=true; input_rate_is_demux_estimate=true',
    );
    final aid = _number(v['aid']);
    final audioReady =
        v['aid'] == 'no' || (aid != null && aid > 0 && audio != null);
    // A buffer=false event or a command reply alone must never finish a window.
    if (beganAfterRestart &&
        seekGeneration == w.seeks &&
        w.restart &&
        began >= w.restartAt &&
        flag('seeking') == false &&
        flag('paused-for-cache') == false &&
        flag('vo-configured') == true &&
        frame &&
        audioReady &&
        pos != null &&
        (pos - w.target.inMicroseconds / 1e6).abs() <= 2) {
      _emit(w, 'target_near_output_sample; physical_display=unverified');
      finish('observed_output');
      return;
    }
    w.sample = Timer(interval, () => unawaited(_sample(w)));
  }

  void finish(String reason) {
    final w = _window;
    if (w == null) return;
    _emit(
      w,
      'end reason=$reason events=${w.events}; '
      'missing_event_is_not_absence=true',
    );
    _window = null;
    w.deadline?.cancel();
    w.sample?.cancel();
    w.finishHttp?.call();
    // Queue teardown before the next owner saves msg-level.
    final closing = w.scope?.close();
    _tail = _tail.then((_) async {
      await closing;
      if (w.scope?.restored == false) {
        record(
          '[LAT130] id=${w.id} producer_restore_failed; warnings_retained=true',
        );
      }
    });
  }

  Future<void> stop(String reason) async {
    finish(reason);
    await _tail;
  }

  Future<void> close() async {
    finish('closed');
    _disposed = true;
    await _tail;
  }
}

class _Window {
  _Window(this.id, this.phase, this.target, this.http, this.finishHttp);
  final int id;
  final String phase;
  final Duration target;
  final void Function(String, String)? http;
  final void Function()? finishHttp;
  final clock = Stopwatch()..start();
  final first = <String>{};
  OpeningLogs? scope;
  Timer? deadline, sample;
  int events = 0, seeks = 0, restartAt = 0;
  bool restart = false;
}
