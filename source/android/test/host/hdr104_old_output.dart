// ignore_for_file: prefer_initializing_formals, unnecessary_non_null_assertion
/// An optional output transaction. The caller serializes it with Surface
/// updates. A failed initialization may deselect video; restore only that
/// original video selection. Playback, audio, subtitle and position stay intact.
class NativeHdrOutput {
  NativeHdrOutput({
    Future<void> Function(Duration)? wait,
    Future<void> Function(String)? refresh,
    bool Function()? current,
  }) : _wait = wait ?? ((duration) => Future<void>.delayed(duration)),
       _refresh = refresh,
       _current = current ?? (() => true);
  final Future<void> Function(Duration) _wait;
  final Future<void> Function(String)? _refresh;
  final bool Function() _current;
  String? _anchor;
  String details = 'not-sampled';
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
    final clock = Stopwatch()..start();
    for (var n = 0; n < 120 && clock.elapsedMilliseconds < 3000; n++) {
      if (!_current()) return false;
      final values = await Future.wait([
        for (final key in const [
          'current-vo',
          'vo-configured',
          'video-frame-info/interlaced',
          'vid',
          'seeking',
        ])
          read(
            key,
          ).timeout(const Duration(milliseconds: 500), onTimeout: () => ''),
      ]);
      final actual = values[0],
          configured = values[1],
          frame = values[2],
          selected = values[3],
          seeking = values[4];
      String safe(String value) =>
          RegExp(r'^[a-zA-Z0-9_.+-]{1,24}$').hasMatch(value)
          ? value
          : 'unavailable';
      details =
          'vo=${safe(actual)};configured=${safe(configured)};'
          'frame=${safe(frame)};vid=${safe(selected)};'
          'seeking=${safe(seeking)};wait-ms=${clock.elapsedMilliseconds}';
      if (!_current()) return false;
      if (actual == output &&
          configured == 'yes' &&
          const {'yes', 'no'}.contains(frame) &&
          selected == _video &&
          (_refresh == null || seeking == 'no')) {
        if (++consecutive >= 2) return true;
      } else {
        consecutive = 0;
      }
      await _wait(const Duration(milliseconds: 25));
    }
    return false;
  }

  String? _position(String value) {
    final seconds = double.tryParse(value);
    return seconds != null && seconds.isFinite && seconds >= 0 && seconds < 1e9
        ? value
        : null;
  }

  Future<void> _refill(Future<String> Function(String) read) async {
    if (_refresh == null || !_current()) return;
    // `seeking` also means an unfinished internal restart in the pinned MPV.
    // Only the command epoch distinguishes a newer user/media intent here;
    // skipping refill during our own restart would wait for a frame forever.
    if (_anchor == null) {
      throw StateError('Output refresh position unavailable');
    }
    await _refresh!(_anchor!);
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
      if (_refresh != null) {
        if (await read('seeking') != 'no' ||
            await read('idle-active') != 'no' ||
            await read('seekable') != 'yes' ||
            !_current()) {
          status = 'snapshot-refresh-unavailable';
          return false;
        }
        _anchor = _position(await read('time-pos'));
        if (_anchor == null) {
          status = 'snapshot-position-unavailable';
          return false;
        }
      }
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
      if (await read('current-vo') != 'gpu') {
        status = 'hdr-output-unavailable';
        throw StateError('HDR renderer not created');
      }
      // The intermediate VO can lose the original selection while its decoder
      // is rebuilt. A live HDR renderer still needs that same video selected.
      if (await read('vid') != _video) {
        status = 'hdr-video';
        await write('vid', _video!);
        if (_videoOption != _video) await write('vid', _videoOption!);
      }
      status = 'hdr-refill';
      await _refill(read);
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
      final rejectedDetails = details;
      try {
        await restore(
          textureSurface: textureSurface,
          width: textureWidth,
          height: textureHeight,
          originalOutput: originalOutput,
          read: read,
          write: write,
        );
      } finally {
        details = 'rejected-$failedStage{$rejectedDetails};restore{$details}';
      }
      status =
          'rejected-$failedStage;${_current() ? 'compatible-ready' : 'compatible-superseded'}';
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
    if (_refresh != null &&
        _current() &&
        const {
          'yes',
          'no',
        }.contains(await read('video-frame-info/interlaced')) &&
        await read('seeking') == 'no') {
      // During an established HDR session use its current frame, not the
      // position saved when playback first opened.
      _anchor = _position(await read('time-pos')) ?? _anchor;
    }
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
      status = 'restore-refill';
      await _refill(read);
      status = 'restore-frame';
      if (_current() && !await _ready(read, originalOutput)) {
        throw StateError('Compatibility video output did not recover');
      }
    }
    _original = null;
    _video = null;
    _videoOption = null;
    _anchor = null;
    token = 0;
    mode = null;
    status = _current() ? 'compatible-ready' : 'compatible-superseded';
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
    _anchor = null;
    token = 0;
    mode = null;
    status = 'closed-detached';
  }
}
