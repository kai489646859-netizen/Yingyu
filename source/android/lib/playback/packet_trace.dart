import 'dart:collection';

/// A bounded numeric observation window, not a timestamp repair. Native text,
/// paths, URLs and packet contents must never be retained by this class.
class DiscPacketTrace {
  static const eventLimit = 20000;
  static const retainedPerKind = 16;
  final _clock = Stopwatch()..start();
  final _rows = <String, ListQueue<String>>{};
  final _counts = <String, int>{};
  int events = 0, rejected = 0;
  bool get exhausted => events >= eventLimit;

  static const _number = r'-?\d{1,22}(?:\.\d{1,9})?';
  static final _packet = RegExp(
    '^append packet to (video|audio): size=(\\d{1,12}) pts=($_number) '
    'dts=($_number) pos=(-?\\d{1,22}) \\[num=(?:1|>1) size=\\d+\\]\\s*\$',
  );
  static final _input = RegExp(
    r'^Queued input buffer (\d{1,8}) size=(\d{1,12}) ts=(-?\d{1,22})\s*$',
  );
  static final _output = RegExp(
    r'^Got output buffer (\d{1,8}) offset=(\d{1,12}) size=(\d{1,12}) '
    r'ts=(-?\d{1,22}) flags=(\d{1,12})\s*$',
  );
  static final _transport = RegExp(
    r'^Yingyu timestamp transport (input|output) token_us=(-?\d{1,22}) '
    r'original_us=(-?\d{1,22}) unknown=([01]) matched=([01])\s*$',
  );
  static final _clockJump = RegExp(
    '^Invalid video timestamp: ($_number) -> ($_number)\\s*\$',
  );

  void _add(String kind, String values) {
    _counts.update(kind, (n) => n + 1, ifAbsent: () => 1);
    final rows = _rows.putIfAbsent(kind, ListQueue.new);
    // Keep the first four and the latest twelve, including the failure edge.
    if (rows.length == retainedPerKind) {
      final first = List.generate(4, (_) => rows.removeFirst());
      rows.removeFirst();
      for (final row in first.reversed) {
        rows.addFirst(row);
      }
    }
    rows.add('${_clock.elapsedMilliseconds}ms $values');
  }

  void add(String prefix, String level, String text) {
    if (exhausted) return;
    events++;
    // Ignore multiline and oversized messages before regex work. This also
    // prevents partial matching of a numeric message followed by a secret.
    final line = text.trim();
    if (line.length > 400 || line.contains('\n') || line.contains('\r')) {
      rejected++;
      return;
    }
    if (const {
      'demux/lavf',
      'demux/edl',
      'demux/timeline',
      'lavf',
      'edl',
    }.contains(prefix)) {
      final m = _packet.firstMatch(line);
      if (m != null) {
        final layer = prefix.contains('lavf') ? '容器' : '时间线';
        _add(
          '$layer/${m[1]}',
          'bytes=${m[2]} pts_s=${m[3]} dts_s=${m[4]} pos=${m[5]}',
        );
        return;
      }
    }
    if (prefix == 'ffmpeg/video') {
      final codec = RegExp(r'^(?:hevc|h264|vp8|vp9|av1|mpeg2)_mediacodec: ');
      final value = line.replaceFirst(codec, '');
      final transport = _transport.firstMatch(value);
      if (transport != null) {
        final unknown = transport[4] == '1';
        final matched = transport[5] == '1';
        // The zero accompanying unknown is a log placeholder, never a media
        // timestamp. Reject inconsistent tuples rather than guessing a source.
        if ((unknown && transport[3] != '0') ||
            (!matched && !unknown) ||
            (transport[1] == 'input' && !matched)) {
          rejected++;
          return;
        }
        _add(
          '硬解时间标识/${transport[1] == 'input' ? '入队' : '出队'}',
          'token_us=${transport[2]} '
              'source_pts_us=${unknown ? 'unknown' : transport[3]} '
              'unknown=${transport[4]} matched=${transport[5]}',
        );
        return;
      }
      final input = _input.firstMatch(value);
      final output = _output.firstMatch(value);
      if (input != null) {
        _add('硬解入队', 'index=${input[1]} bytes=${input[2]} pts_us=${input[3]}');
        return;
      }
      if (output != null) {
        _add(
          '硬解出队',
          'index=${output[1]} offset=${output[2]} '
              'bytes=${output[3]} pts_us=${output[4]} flags=${output[5]}',
        );
        return;
      }
      if (value == 'Input packet is missing PTS') {
        _add('输入缺PTS', 'observed=1');
        return;
      }
    }
    if (prefix == 'cplayer') {
      final m = _clockJump.firstMatch(line);
      if (m != null) {
        _add('显示时钟异常', 'from_s=${m[1]} to_s=${m[2]}');
        return;
      }
    }
    if (prefix == 'ad' && line == 'Error decoding audio.') {
      _add('音频解码错误', 'observed=1');
      return;
    }
    if (prefix == 'overflow') {
      _add('日志队列溢出', 'observed=1');
      return;
    }
    rejected++;
  }

  List<String> finish() => [
    '原盘数值诊断结束：观察=${_clock.elapsedMilliseconds}ms；'
        '收到=$events；忽略=$rejected；事件上限=$eventLimit；'
        '原生队列可能丢记录，缺少记录不能证明没有异常；不是帧对应关系或实播验收',
    for (final entry in _rows.entries) ...[
      '原盘数值/${entry.key}：观察数=${_counts[entry.key]}；保留=${entry.value.length}',
      for (final row in entry.value) '原盘数值/${entry.key}：$row',
    ],
  ];
}
