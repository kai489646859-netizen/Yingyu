/// An optional output transaction. The caller serializes it with Surface
/// updates. A failed initialization may deselect video; restore only that
/// original video selection. Playback, audio, subtitle and position stay intact.
class NativeHdrOutput {
  NativeHdrOutput({Future<void> Function(Duration)? wait})
    : _wait = wait ?? ((duration) => Future<void>.delayed(duration));
  final Future<void> Function(Duration) _wait;
  Map<String, String>? _original;
  String? _video;
  String? _videoOption;
  String status = 'unchanged';
  int token = 0;
  String? mode;
  bool _keepPanscan = false;
  bool get active => _original != null;
  bool _equivalent(String actual, String expected) {
    if (actual == expected) return true;
    final a = double.tryParse(actual), b = double.tryParse(expected);
    return a != null && b != null && a.isFinite && b.isFinite && a == b;
  }

  static const _keys = [
    'gpu-context',
    'target-prim',
    'target-trc',
    'target-peak',
    'tone-mapping',
    'dither',
    'dither-depth',
    'panscan',
  ];

  Future<bool> _ready(
    Future<String> Function(String) read,
    String output,
  ) async {
    var consecutive = 0;
    for (var n = 0; n < 40; n++) {
      final actual = await read('current-vo');
      final configured = await read('vo-configured');
      final frame = await read('video-frame-info/interlaced');
      final selected = await read('vid');
      if (actual == output &&
          configured == 'yes' &&
          const {'yes', 'no'}.contains(frame) &&
          selected == _video) {
        if (++consecutive >= 2) return true;
      } else {
        consecutive = 0;
      }
      await _wait(const Duration(milliseconds: 25));
    }
    return false;
  }

  Future<bool> apply({
    required int surface,
    required int width,
    required int height,
    required String transfer,
    required bool fill,
    bool keepPanscan = false,
    required int textureSurface,
    required int textureWidth,
    required int textureHeight,
    required String originalOutput,
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    if (surface == 0) {
      await restore(
        textureSurface: textureSurface,
        width: textureWidth,
        height: textureHeight,
        originalOutput: originalOutput,
        read: read,
        write: write,
      );
      return false;
    }
    if (surface < 0 ||
        !const {'pq', 'hlg'}.contains(transfer) ||
        width <= 1 ||
        height <= 1 ||
        width > 16384 ||
        height > 16384 ||
        textureSurface <= 0 ||
        textureWidth <= 1 ||
        textureHeight <= 1) {
      return false;
    }
    if (surface == token && mode == transfer) {
      await write('android-surface-size', '${width}x$height');
      if (!_keepPanscan) await write('panscan', fill ? '1' : '0');
      return true;
    }
    if (active) {
      throw StateError('HDR surface replacement requires restoration');
    }
    final saved = <String, String>{};
    try {
      status = 'snapshot';
      final selected = await read('vid');
      if ((int.tryParse(selected) ?? 0) <= 0 ||
          await read('vo-configured') != 'yes' ||
          !const {
            'yes',
            'no',
          }.contains(await read('video-frame-info/interlaced'))) {
        status = 'snapshot-video-unavailable';
        return false;
      }
      _video = selected;
      final requested = await read('options/vid');
      if (requested != 'auto' && (int.tryParse(requested) ?? 0) <= 0) {
        status = 'snapshot-video-option-unavailable';
        return false;
      }
      _videoOption = requested;
      for (final key in _keys) {
        if (key != 'panscan' || !keepPanscan) {
          final value = await read('options/$key');
          if (value.isEmpty) {
            status = 'snapshot-option-unavailable';
            return false;
          }
          saved[key] = value;
        }
      }
    } catch (_) {
      return false;
    }
    _keepPanscan = keepPanscan;
    _original = saved;
    try {
      status = 'detach';
      await write('vo', 'null');
      if (await read('options/vo') != 'null') {
        throw StateError('Old output did not detach');
      }
      final settings = {
        'gpu-context': 'android-hdr-$transfer',
        'target-prim': 'bt.2020', 'target-trc': transfer,
        // Output target is 1000 nits; this is not a display measurement or
        // copied mastering metadata. MPV maps content to this target.
        'target-peak': '1000', 'tone-mapping': 'bt.2390',
        'dither': 'fruit', 'dither-depth': '10',
        if (!keepPanscan) 'panscan': fill ? '1' : '0',
      };
      for (final entry in settings.entries) {
        status = 'option-${entry.key}';
        await write(entry.key, entry.value);
        final actual = await read('options/${entry.key}');
        if (!_equivalent(actual, entry.value)) {
          throw StateError('HDR option not applied: ${entry.key}');
        }
      }
      await write('android-surface-size', '${width}x$height');
      status = 'surface';
      await write('wid', '$surface');
      if (await read('options/wid') != '$surface') {
        throw StateError('HDR surface not selected');
      }
      await write('vo', 'gpu');
      status = 'hdr-frame';
      if (!await _ready(read, 'gpu')) {
        throw StateError('HDR EGL output unavailable');
      }
      token = surface;
      mode = transfer;
      status = 'hdr-ready';
      return true;
    } catch (_) {
      final failedStage = status;
      await restore(
        textureSurface: textureSurface,
        width: textureWidth,
        height: textureHeight,
        originalOutput: originalOutput,
        read: read,
        write: write,
      );
      status = 'rejected-$failedStage;compatible-ready';
      return false;
    }
  }

  Future<void> restore({
    required int textureSurface,
    required int width,
    required int height,
    required String originalOutput,
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    final saved = _original;
    if (saved == null) return;
    await write('vo', 'null');
    if (await read('options/vo') != 'null') {
      throw StateError('HDR output did not detach');
    }
    await write('wid', '0');
    if (await read('options/wid') != '0') {
      throw StateError('HDR surface did not detach');
    }
    // Attempt every field. A failed restore remains pending and is a real
    // failure; another media cannot inherit an HDR context or PQ target.
    Object? failure;
    for (final entry in saved.entries) {
      try {
        await write(entry.key, entry.value);
        final actual = await read('options/${entry.key}');
        if (!_equivalent(actual, entry.value)) {
          throw StateError('HDR option restore failed');
        }
      } catch (error) {
        failure ??= error;
      }
    }
    if (failure != null) {
      throw StateError('HDR compatibility restoration failed');
    }
    await write('android-surface-size', '${width}x$height');
    await write('wid', '$textureSurface');
    if (await read('options/wid') != '$textureSurface') {
      throw StateError('Compatibility Surface not restored');
    }
    await write('vo', textureSurface == 0 ? 'null' : originalOutput);
    if (await read('options/vo') !=
        (textureSurface == 0 ? 'null' : originalOutput)) {
      throw StateError('Compatibility output not restored');
    }
    if (textureSurface == 0) {
      status = 'restore-surface-unavailable';
      throw StateError('Compatibility Surface unavailable');
    }
    if (textureSurface != 0) {
      // A failed VO initialization can deselect the video track in MPV even
      // when options/vo subsequently reads back correctly. Restore only the
      // previously selected video; audio/subtitle selections are untouched.
      if (_video == null || (int.tryParse(_video!) ?? 0) <= 0) {
        throw StateError('Compatibility video snapshot unavailable');
      }
      if (await read('vid') != _video) {
        status = 'restore-video';
        await write('vid', _video!);
        if (_videoOption != _video) await write('vid', _videoOption!);
      }
      status = 'restore-frame';
      if (!await _ready(read, originalOutput)) {
        throw StateError('Compatibility video output did not recover');
      }
    }
    _original = null;
    _video = null;
    _videoOption = null;
    token = 0;
    mode = null;
    status = 'compatible-ready';
  }

  /// End ownership for player destruction. Unlike fallback during playback,
  /// this must not recreate a renderer, select video, or wait for a frame.
  Future<void> detachForClose({
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    if (!active) return;
    status = 'close-detach';
    await write('vo', 'null');
    if (await read('options/vo') != 'null') {
      throw StateError('Closing HDR output did not detach');
    }
    await write('wid', '0');
    if (await read('options/wid') != '0') {
      throw StateError('Closing HDR surface did not detach');
    }
    _original = null;
    _video = null;
    _videoOption = null;
    token = 0;
    mode = null;
    status = 'closed-detached';
  }
}
