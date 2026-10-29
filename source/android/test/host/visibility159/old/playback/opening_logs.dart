import 'dart:async';

/// Producer-side startup diagnostics policy. Native IO is supplied by MPV.
class OpeningLogs {
  OpeningLogs({
    required this.read,
    required this.write,
    required this.request,
    this.duration = const Duration(seconds: 8),
    this.rulesOverride,
  });
  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final int Function(String) request;
  final Duration duration;
  final String? rulesOverride;
  static const rules =
      'all=warn,vd=v,ffmpeg=trace,ffmpeg/video=v,'
      'ffmpeg/audio=warn,ffmpeg/demuxer=warn';
  Future<void> _tail = Future.value();
  String? _saved;
  Timer? _timer;
  bool _closed = false;
  bool enabled = false, restored = true;

  Future<void> start() => _tail = _tail.then((_) async {
    if (_closed) return;
    try {
      _saved = await read('options/msg-level');
      if (_closed) return;
      await write('msg-level', rulesOverride ?? rules);
      if (_closed) return;
      if (request('terminal-default') < 0) {
        throw StateError('log scope unavailable');
      }
      enabled = true;
      _timer = Timer(duration, () => unawaited(close()));
    } catch (_) {
      await _restore();
    }
  });

  Future<void> restrict(String rules) => _tail = _tail.then((_) async {
    if (_closed || !enabled) return;
    try {
      await write('msg-level', rules);
    } catch (_) {
      await _restore();
    }
  });

  Future<void> _restore() async {
    _timer?.cancel();
    enabled = false;
    try {
      final saved = _saved;
      if (saved != null) await write('msg-level', saved);
    } catch (_) {
      restored = false;
    } finally {
      // Even a failed optional prefix restore cannot leave packet/frame
      // traffic subscribed in Dart. Real warnings and errors remain enabled.
      try {
        request('warn');
      } catch (_) {
        restored = false;
      }
    }
  }

  Future<void> close() {
    if (_closed) return _tail;
    _closed = true;
    return _tail = _tail.then((_) => _restore());
  }
}
