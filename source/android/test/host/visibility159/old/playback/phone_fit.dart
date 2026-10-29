import 'dart:async';

Future<bool> phoneFitReadbackAllowed(
  Future<String> Function(String) read,
) async {
  try {
    final cache = double.tryParse(await read('demuxer-cache-duration'));
    if (cache == null || !cache.isFinite || cache < 8 || cache > 120) {
      return false;
    }
    return await read('paused-for-cache') == 'no' &&
        await read('seeking') == 'no';
  } catch (_) {
    return false;
  }
}

/// One phone session owns its viewport settings and crop decision. Callers
/// provide current-generation checks; tablet callers never create this object.
class PhoneFit {
  PhoneFit({
    required this.read,
    required this.write,
    required this.detect,
    required this.healthy,
    required this.record,
    this.onRestoreFailure,
    this.viewportAspect = 2.2,
  });
  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final Future<List<int>?> Function() detect;
  final bool Function() healthy;
  final void Function(String) record;
  final void Function()? onRestoreFailure;
  final double viewportAspect;
  double? get adaptedAspect => _adaptation.isEmpty || _candidate == null
      ? null
      : _candidate![0] / (_candidate![1] - _candidate![2] * 2);
  final _saved = <String, String>{};
  Timer? _timer;
  bool _busy = false, _closed = false, _fill = false;
  int _generation = 0, _matches = 0, _misses = 0;
  List<int>? _candidate;
  String _adaptation = '';
  Future<void> _queue = Future.value();

  Future<void> configure({required bool fill}) {
    final generation = ++_generation;
    _timer?.cancel();
    _fill = fill;
    final result = _queue.then((_) async {
      if (_closed || generation != _generation) return;
      const keys = ['panscan', 'video-crop', 'stretch-image-subs-to-screen'];
      for (final key in keys) {
        _saved[key] ??= await read(key);
      }
      if (_closed || generation != _generation) return;
      try {
        await _set('stretch-image-subs-to-screen', 'yes');
        await _set('panscan', fill ? '1' : '0');
        await _set('video-crop', _saved['video-crop']!);
        _adaptation = '';
      } catch (_) {
        try {
          await restore();
        } catch (_) {
          onRestoreFailure?.call();
        }
        rethrow;
      }
      if (!fill && !_closed && generation == _generation) {
        _matches = _misses = 0;
        _candidate = null;
        // Keep optional readback outside opening and the first few seconds.
        _timer = Timer.periodic(
          const Duration(seconds: 4),
          (_) => unawaited(_probe(generation)),
        );
      }
    });
    _queue = result.catchError((Object _) {});
    return result;
  }

  Future<void> _set(String key, String value) async {
    await write(key, value);
    final actual = await read(key);
    final a = double.tryParse(actual), b = double.tryParse(value);
    if (actual != value && (a == null || b == null || (a - b).abs() > .0001)) {
      throw StateError('手机画面参数未确认');
    }
  }

  Future<void> _probe(int generation) async {
    if (_busy || _closed || _fill || generation != _generation || !healthy()) {
      return;
    }
    _busy = true;
    final job = _queue.then((_) async {
      try {
        if (_closed || generation != _generation || !healthy()) return;
        final sample = await detect();
        if (_closed || generation != _generation || !healthy()) return;
        if (sample == null) {
          _matches = 0;
          // Dark scenes are not evidence that the encoded bands disappeared.
          if (_adaptation.isEmpty && ++_misses >= 3) _timer?.cancel();
          return;
        }
        if (sample.length != 3 ||
            sample[0] <= 0 ||
            sample[1] <= 0 ||
            sample[2] < 0) {
          return;
        }
        final old = _candidate;
        if (_adaptation.isNotEmpty &&
            (sample[2] == 0 ||
                old == null ||
                old[0] != sample[0] ||
                old[1] != sample[1] ||
                sample[2] < old[2] - 4)) {
          await _set('panscan', _saved['panscan']!);
          _adaptation = '';
          _timer?.cancel();
          record('手机适应：画面边界变化，已恢复完整画面');
          return;
        }
        if (sample[2] == 0) {
          _matches = 0;
          if (++_misses >= 3) _timer?.cancel();
          return;
        }
        _matches =
            old != null &&
                old[0] == sample[0] &&
                old[1] == sample[1] &&
                (old[2] - sample[2]).abs() <= 4
            ? _matches + 1
            : 1;
        _candidate = sample;
        if (_matches < 3 || _saved['video-crop']!.isNotEmpty) return;
        final originalAspect = sample[0] / sample[1];
        final fullScale = viewportAspect / originalAspect;
        if (fullScale <= 1 || !fullScale.isFinite) return;
        final safeScale = sample[1] / (sample[1] - sample[2] * 2);
        final pan = ((safeScale - 1) / (fullScale - 1)).clamp(0.0, 1.0);
        final next = pan.toStringAsFixed(6);
        if (_adaptation == next) return;
        // Panscan leaves the unscaled frame available for subsequent checks.
        // Its upper bound fits inside the confirmed encoded bands. The native
        // subtitle canvas remains the full phone viewport.
        await _set('panscan', next);
        if (_closed || generation != _generation) return;
        _adaptation = next;
        record('手机适应：多帧确认上下黑边，调整显示区域；字幕保留在屏幕内');
        _timer?.cancel();
        _timer = Timer.periodic(
          const Duration(seconds: 15),
          (_) => unawaited(_probe(generation)),
        );
      } catch (_) {
        _timer?.cancel();
        if (!_closed && generation == _generation) {
          try {
            await restore();
            record('手机适应暂不可用，已恢复完整画面');
          } catch (_) {
            onRestoreFailure?.call();
          }
        }
      } finally {
        _busy = false;
      }
    });
    _queue = job.catchError((Object _) {});
    await job;
  }

  Future<void> restore() async {
    Object? failure;
    for (final entry in _saved.entries) {
      try {
        await _set(entry.key, entry.value);
      } catch (error) {
        failure ??= error;
      }
    }
    _adaptation = '';
    if (failure != null) throw StateError('手机画面参数恢复失败：$failure');
  }

  void dispose() {
    _closed = true;
    _generation++;
    _timer?.cancel();
  }
}
