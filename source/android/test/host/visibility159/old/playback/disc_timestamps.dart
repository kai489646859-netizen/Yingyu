/// Enable conservative A/V cache duration only on a validated disc timeline.
/// Snapshots survive failed rollback; ordinary media restores the exact value.
class DiscCacheSetup {
  static const option = 'demuxer-yingyu-cache-av-min';
  String? _previous;
  bool _configured = false;
  Future<void> _tail = Future.value();

  Future<bool> prepare({
    required bool disc,
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) {
    final job = _tail.then((_) async {
      if (!disc) {
        await _restore(read, write);
        return false;
      }
      if (_configured) return true;
      await _restore(read, write);
      final original = await read('options/$option');
      if (!const {'yes', 'no'}.contains(original)) {
        throw StateError('原盘缓存计算能力未知');
      }
      _previous = original;
      try {
        if (original != 'yes') await write(option, 'yes');
        if (await read('options/$option') != 'yes') {
          throw StateError('原盘音视频缓存计算未生效');
        }
        _configured = true;
        return true;
      } catch (_) {
        await _restore(read, write);
        rethrow;
      }
    });
    _tail = job.then<void>((_) {}, onError: (Object _) {});
    return job;
  }

  Future<void> _restore(
    Future<String> Function(String) read,
    Future<void> Function(String, String) write,
  ) async {
    _configured = false;
    final previous = _previous;
    if (previous == null) return;
    await write(option, previous);
    if (await read('options/$option') != previous) {
      throw StateError('原盘缓存计算原值未能恢复');
    }
    _previous = null;
  }
}

/// FFmpeg packet lookahead only on validated discs; preserve real/unknown PTS.
class DiscTimestampSetup {
  static const _decoderOption = 'vd-lavc-yingyu-disc-pts';
  String? _previous;
  String? _previousDecoder;
  bool _configured = false;
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
      await _restore(read, command);
      return null;
    }
    if (_configured) return null;
    // Keep failed rollback snapshots until a later restore succeeds.
    await _restore(read, command);
    const value = 'fflags=+genpts';
    try {
      final previous = await read('options/$option');
      final decoder = await read('options/$_decoderOption');
      if (!const {'yes', 'no'}.contains(decoder)) {
        throw StateError('原盘时间戳保护设置未知');
      }
      _previousDecoder = decoder;
      // Never rewrite an explicit format-flags map or its protocol whitelist.
      final explicitFlags = previous.contains('fflags=');
      if (!explicitFlags) {
        _previous = previous;
        await command(['change-list', option, 'append', value]);
        final expected = previous.isEmpty ? value : '$previous,$value';
        if (await read('options/$option') != expected) {
          throw StateError('原盘时间戳设置未生效');
        }
      }
      // This MPV capability only reaches a copying MediaCodec decoder. Its
      // native gate excludes ordinary software, Surface and Dolby mapping.
      if (decoder != 'yes') await command(['set', _decoderOption, 'yes']);
      if (await read('options/$_decoderOption') != 'yes') {
        throw StateError('原盘复制式硬解时间戳保护未生效');
      }
      _configured = true;
      return '${explicitFlags ? "保留已有容器时间戳设置" : "原盘缺失 PTS 尝试由容器现有 DTS 补全"}；'
          '复制式硬解保留真实与未知时间戳身份；原画与准确定位保持';
    } catch (_) {
      await _restore(read, command);
      return '原盘时间戳补全未启用，已恢复原配置';
    }
  }

  Future<void> _restore(
    Future<String> Function(String) read,
    Future<void> Function(List<String>) command,
  ) async {
    _configured = false;
    var failed = false;
    final decoder = _previousDecoder;
    if (decoder != null) {
      try {
        await command(['set', _decoderOption, decoder]);
        if (await read('options/$_decoderOption') != decoder) {
          throw StateError('原盘解码时间戳设置未能恢复');
        }
        _previousDecoder = null;
      } catch (_) {
        failed = true;
      }
    }
    final previous = _previous;
    if (previous != null) {
      try {
        await command(['change-list', 'demuxer-lavf-o', 'remove', 'fflags']);
        if (await read('options/demuxer-lavf-o') != previous) {
          throw StateError('原盘容器时间戳设置未能恢复');
        }
        _previous = null;
      } catch (_) {
        failed = true;
      }
    }
    if (failed) throw StateError('原盘时间戳设置未能恢复');
  }
}
