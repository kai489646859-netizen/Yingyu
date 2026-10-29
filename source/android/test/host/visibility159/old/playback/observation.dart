import 'dart:convert';

/// The pinned MPV exposes this node as JSON through the string API; individual
/// slash subproperties are not implemented. Keep only bounded scalar facts.
Future<Map<String, String>> readPlaybackCache(
  Future<String> Function(String) read,
) async {
  try {
    final raw = await read(
      'demuxer-cache-state',
    ).timeout(const Duration(milliseconds: 300));
    if (raw.length > 65536) return {};
    final node = jsonDecode(raw);
    if (node is! Map) return {};
    return {
      for (final key in const [
        'fw-bytes',
        'raw-input-rate',
        'reader-pts',
        'cache-end',
      ])
        if (node[key] case final num value)
          if (value.isFinite && value >= 0)
            'demuxer-cache-state/$key': value.toString(),
    };
  } catch (_) {
    return {};
  }
}

/// Read-only playback facts. These values never control buffering or decoding.
abstract class PlaybackDiagnosticState {
  String get diagnosticState;
}

enum SpeedChangeSource {
  menu('倍速菜单'),
  holdStart('长按开始'),
  holdEnd('长按松手'),
  holdCancel('长按取消'),
  holdRestore('离开或中断时恢复'),
  continuity('同剧连播沿用'),
  direct('应用调用');

  const SpeedChangeSource(this.label);
  final String label;
}

enum SeekSource {
  slider('进度条'),
  gesture('横滑手势'),
  skip('快进快退按钮'),
  menu('播放菜单'),
  direct('应用调用');

  const SeekSource(this.label);
  final String label;
}

enum PauseSource {
  lifecycle('应用后台或锁屏'),
  interruption('音频中断');

  const PauseSource(this.label);
  final String label;
}

double? _number(String? text) {
  final value = double.tryParse(text ?? '');
  return value != null && value.isFinite ? value : null;
}

/// Summarize existing MPV samples without another property or network request.
/// Seek/rate/load boundaries invalidate both in-flight samples and deltas.
class PlaybackObservation {
  int generation = 0;
  Map<String, String>? _values;
  Duration? _at;
  double _speed = 1;
  String _delta = '区间统计=首个样本';

  void invalidate() {
    generation++;
    _values = null;
    _at = null;
    _delta = '区间统计=首个样本';
  }

  bool record({
    required int sampleGeneration,
    required Duration now,
    required double speed,
    required Map<String, String> values,
  }) {
    if (sampleGeneration != generation) return false;
    final old = _values;
    final at = _at;
    final parts = <String>[];
    if (old != null && at != null && now > at) {
      parts.add('采样间隔=${(now - at).inMilliseconds} ms');
      for (final entry in const {
        'decoder-frame-drop-count': '解码丢帧新增',
        'frame-drop-count': '输出丢帧新增',
      }.entries) {
        final before = _number(old[entry.key]);
        final after = _number(values[entry.key]);
        parts.add(
          '${entry.value}=${before == null || after == null
              ? "未提供"
              : after < before
              ? "计数已重置"
              : (after - before).toInt()}',
        );
      }
    }
    _delta = parts.isEmpty ? '区间统计=首个样本' : parts.join('；');
    // Strict whitelist: no native messages, paths or stream titles retained.
    _values = {
      for (final key in const [
        'demuxer-cache-duration',
        'time-pos',
        'audio-pts',
        'avsync',
        'speed',
        'decoder-frame-drop-count',
        'frame-drop-count',
      ])
        if (_number(values[key]) != null) key: values[key]!,
      for (final key in const [
        'demuxer-cache-state/fw-bytes',
        'demuxer-cache-state/raw-input-rate',
        'demuxer-cache-state/reader-pts',
        'demuxer-cache-state/cache-end',
      ])
        if (_number(values[key]) case final double value)
          if (value >= 0) key: value.toString(),
      for (final key in const ['paused-for-cache', 'seeking', 'vo-configured'])
        if (const {'yes', 'no'}.contains(values[key])) key: values[key]!,
    };
    _at = now;
    _speed = speed;
    return true;
  }

  String describe(Duration now) {
    final values = _values;
    final at = _at;
    if (values == null || at == null) return '最近音画采样=尚未取得';
    final cache = _number(values['demuxer-cache-duration']);
    final seconds = cache != null && cache >= 0 && _speed.isFinite && _speed > 0
        ? (cache / _speed).toStringAsFixed(2)
        : '未提供';
    return '采样距今=${(now - at).inMilliseconds.clamp(0, 1 << 50)} ms；'
        '采样倍速=$_speed；内核倍速=${values['speed'] ?? "未提供"}；缓存折合实际时间≈$seconds 秒（估算）；'
        '缓存媒体时间=${values['demuxer-cache-duration'] ?? "未提供"} 秒；'
        '视频时钟=${values['time-pos'] ?? "未提供"} 秒；'
        '音频时钟=${values['audio-pts'] ?? "未提供"} 秒；'
        '音画差=${values['avsync'] ?? "未提供"} 秒；'
        '缓存暂停=${values['paused-for-cache'] ?? "未提供"}；'
        '正在定位=${values['seeking'] ?? "未提供"}；'
        '前向包缓存=${values['demuxer-cache-state/fw-bytes'] ?? "未提供"} 字节（估算）；'
        '内核输入速率=${values['demuxer-cache-state/raw-input-rate'] ?? "未提供"} 字节/秒（估算，非实测带宽）；'
        '读取起点=${values['demuxer-cache-state/reader-pts'] ?? "未提供"} 秒；'
        '缓存末端=${values['demuxer-cache-state/cache-end'] ?? "未提供"} 秒；$_delta';
  }
}
