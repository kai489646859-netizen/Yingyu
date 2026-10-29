/// Use FFmpeg's packet lookahead only for a validated disc timeline. Existing
/// PTS are untouched; missing PTS can be derived from available DTS in demux
/// order (including B frames), before MediaCodec can substitute zero for them.
/// No frame-rate, wall-clock or audio-clock timestamp is fabricated here.
class DiscTimestampSetup {
  String? _previous;
  Future<void> _tail = Future.value();

  Future<String?> prepare({
    required bool disc,
    required Future<String> Function(String) read,
    required Future<void> Function(List<String>) command,
  }) {
    final result = _tail.then((_) => _prepare(disc, read, command));
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String?> _prepare(
    bool disc,
    Future<String> Function(String) read,
    Future<void> Function(List<String>) command,
  ) async {
    const option = 'demuxer-lavf-o';
    if (!disc) {
      if (_previous == null) return null;
      await command(['change-list', option, 'remove', 'fflags']);
      if (await read('options/$option') != _previous) {
        throw StateError('普通媒体时间戳设置未能恢复');
      }
      _previous = null;
      return null;
    }
    if (_previous != null) return null;
    final previous = await read('options/$option');
    // Never rewrite an explicit format-flags map or its protocol whitelist.
    if (previous.contains('fflags=')) return '保留已有容器时间戳设置';
    const value = 'fflags=+genpts';
    try {
      await command(['change-list', option, 'append', value]);
      final expected = previous.isEmpty ? value : '$previous,$value';
      if (await read('options/$option') != expected) {
        throw StateError('原盘时间戳设置未生效');
      }
      _previous = previous;
      return '原盘缺失 PTS 由容器现有 DTS 补全；已有时间戳、原画与准确定位保留';
    } catch (_) {
      await command(['change-list', option, 'remove', 'fflags']);
      if (await read('options/$option') != previous) {
        throw StateError('原盘时间戳设置未能恢复');
      }
      return '原盘时间戳补全未启用，已恢复原配置';
    }
  }
}
