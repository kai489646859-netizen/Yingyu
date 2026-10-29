/// An optional output transaction. The caller serializes it with Surface
/// updates. No playback, decoder, track, position or volume command is issued.
class NativeHdrOutput {
  Map<String, String>? _original;
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
        height > 16384) {
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
      for (final key in _keys) {
        if (key != 'panscan' || !keepPanscan) {
          saved[key] = await read('options/$key');
        }
      }
    } catch (_) {
      return false;
    }
    _keepPanscan = keepPanscan;
    _original = saved;
    try {
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
        await write(entry.key, entry.value);
        final actual = await read('options/${entry.key}');
        if (!_equivalent(actual, entry.value)) {
          throw StateError('HDR option not applied: ${entry.key}');
        }
      }
      await write('android-surface-size', '${width}x$height');
      await write('wid', '$surface');
      if (await read('options/wid') != '$surface') {
        throw StateError('HDR surface not selected');
      }
      await write('vo', 'gpu');
      if (await read('current-vo') != 'gpu') {
        throw StateError('HDR EGL output unavailable');
      }
      token = surface;
      mode = transfer;
      return true;
    } catch (_) {
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
    _original = null;
    token = 0;
    mode = null;
  }
}
