import 'dart:async';

/// Configure once before opening media. Keep MPV's existing pitch-preserving
/// algorithm alive at 1x too, instead of draining/removing it on every release.
/// OpenSLES otherwise defaults to 250 ms per enqueue in the pinned MPV source.
class RateAudioSetup {
  Future<List<String>>? _job;

  Future<List<String>> prepare({
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) => _job ??= _prepare(read, write);

  Future<List<String>> _prepare(
    Future<String> Function(String) read,
    Future<void> Function(String, String) write,
  ) async {
    final result = <String>[];
    for (final option in const {
      'af': 'scaletempo2',
      'opensles-buffer-size-in-ms': '100',
    }.entries) {
      String? previous;
      var attempted = false;
      try {
        previous = await read('options/${option.key}');
        // Never replace a filter chain supplied elsewhere by the player.
        if (option.key == 'af' && previous.isNotEmpty) {
          result.add('音频滤镜已有配置，保留');
          continue;
        }
        attempted = true;
        await write(option.key, option.value);
        result.add('${option.key}=${option.value} 配置已接受');
      } catch (_) {
        if (attempted && previous != null) {
          // A failed optional optimization must not leave a partial setting.
          await write(option.key, previous);
        }
        result.add('${option.key} 优化未启用，保留原配置');
      }
    }
    return result;
  }
}

/// A short read-only window around a speed change, separate from recovery.
/// No native messages, titles, URLs or account values enter these records.
class RateSwitchProbe {
  RateSwitchProbe({
    required this.read,
    required this.record,
    required this.active,
  });
  final Future<String> Function(String) read;
  final void Function(String) record;
  final bool Function() active;
  Timer? _timer;
  int _generation = 0;
  bool _busy = false;

  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void start(double from, double to) {
    cancel();
    if (!active()) return;
    final generation = _generation;
    final elapsed = Stopwatch()..start();
    var ticks = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (++ticks >= 8) timer.cancel();
      if (!active()) {
        cancel();
        return;
      }
      if (!_busy) unawaited(_sample(generation, elapsed, from, to));
    });
  }

  Future<void> _sample(
    int generation,
    Stopwatch elapsed,
    double from,
    double to,
  ) async {
    _busy = true;
    final values = <String>[];
    try {
      for (final key in const [
        'speed',
        'time-pos',
        'audio-pts',
        'avsync',
        'frame-drop-count',
        'decoder-frame-drop-count',
        'paused-for-cache',
        'seeking',
      ]) {
        if (generation != _generation || !active()) return;
        var safe = '未提供';
        try {
          final value = await read(
            key,
          ).timeout(const Duration(milliseconds: 180));
          final number = double.tryParse(value);
          if (value.length <= 40 &&
              ((number != null && number.isFinite) ||
                  (const ['paused-for-cache', 'seeking'].contains(key) &&
                      const ['yes', 'no'].contains(value)))) {
            safe = value;
          }
        } catch (_) {
          /* A missing diagnostic property does not affect playback. */
        }
        values.add('$key=$safe');
      }
      if (generation == _generation && active()) {
        record(
          '切速短窗：$from→$to；命令后=${elapsed.elapsedMilliseconds} ms；${values.join('；')}',
        );
      }
    } finally {
      _busy = false;
    }
  }
}

Map<String, String> changedDiscOptions(
  Map<String, String>? previous,
  Map<String, String> next,
) => {
  for (final option in next.entries)
    if (previous?[option.key] != option.value) option.key: option.value,
};
