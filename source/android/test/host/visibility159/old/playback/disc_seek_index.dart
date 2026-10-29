import 'dart:convert';

/// Only validated CLPI points for this native session may reach the demuxer.
/// PTS is not converted into a DTS index; MPV still decodes to the exact target.
String discSeekIndex(String session, String json, Set<String> clips) {
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(session) ||
      json.length > 4 * 1024 * 1024) {
    return '';
  }
  try {
    final data = jsonDecode(json);
    if (data is! List || data.isEmpty || data.length > 4096) return '';
    final blocks = <String>[];
    final seen = <String>{};
    for (final row in data) {
      if (row is! Map) return '';
      final clip = row['clip'], pid = row['pid'], packets = row['packetCount'];
      final points = row['points'];
      if (clip is! String ||
          !RegExp(r'^\d{5}$').hasMatch(clip) ||
          !clips.contains(clip) ||
          !seen.add(clip) ||
          pid is! int ||
          pid < 1 ||
          pid > 8191 ||
          packets is! int ||
          packets < 1 ||
          packets > 0xffffffff ||
          points is! List ||
          points.length < 2 ||
          points.length > 65536) {
        return '';
      }
      var lastPts = -1, lastSpn = -1;
      final encoded = <String>[];
      for (final point in points) {
        if (point is! List || point.length != 2) return '';
        final pts = point[0], spn = point[1];
        if (pts is! int ||
            pts <= lastPts ||
            pts > 0x1fffffffe ||
            spn is! int ||
            spn <= lastSpn ||
            spn >= packets) {
          return '';
        }
        encoded.add('$pts:$spn');
        lastPts = pts;
        lastSpn = spn;
      }
      blocks.add('$clip,$pid,$packets,${encoded.join(',')}');
    }
    final result = 'YI1|$session|${blocks.join('|')}';
    return result.length <= 4 * 1024 * 1024 ? result : '';
  } catch (_) {
    return '';
  }
}

/// Restore the original option before a new media load. Failure to confirm an
/// optional optimization restores it; failure to restore must remain visible.
class DiscSeekIndexSetup {
  static const key = 'demuxer-lavf-yingyu-disc-index';
  String? _previous;

  Future<bool> prepare({
    required String index,
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    if (_previous case final previous?) {
      await write(key, previous);
      if (await read('options/$key') != previous) {
        throw StateError('原盘定位配置未能恢复');
      }
      _previous = null;
    }
    if (index.isEmpty) return false;
    String original;
    try {
      original = await read('options/$key');
    } catch (_) {
      return false;
    }
    // Never replace a pre-existing explicit setting.
    if (original.isNotEmpty) return false;
    _previous = original;
    try {
      await write(key, index);
      if (await read('options/$key') != index) throw StateError('未确认原盘定位配置');
      return true;
    } catch (_) {
      await write(key, original);
      if (await read('options/$key') != original) {
        throw StateError('原盘定位配置未能恢复');
      }
      _previous = null;
      return false;
    }
  }
}
