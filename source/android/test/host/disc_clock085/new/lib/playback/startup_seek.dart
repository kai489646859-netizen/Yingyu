/// The pinned media_kit disables MPV's normal pre-target decoder discard.
/// During initial exact resume, enable it only without timestamp-changing
/// filters. Frames at/after the requested position and playback stay unchanged.
class StartupSeekSetup {
  String? _previous;

  Future<bool> prepare({
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    if (_previous != null) return false;
    try {
      final old = await read('hr-seek-framedrop');
      final filters = await read('vf');
      final deinterlace = await read('deinterlace');
      if (old != 'no' ||
          !const {'', '[]'}.contains(filters.trim()) ||
          deinterlace != 'no') {
        return false;
      }
      _previous = old;
      await write('hr-seek-framedrop', 'yes');
      if (await read('hr-seek-framedrop') != 'yes') {
        await restore(read: read, write: write);
        return false;
      }
      return true;
    } catch (_) {
      await restore(read: read, write: write);
      return false;
    }
  }

  Future<void> restore({
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
  }) async {
    final previous = _previous;
    if (previous == null) return;
    await write('hr-seek-framedrop', previous);
    if (await read('hr-seek-framedrop') != previous) {
      throw StateError('Initial seek option was not restored');
    }
    _previous = null;
  }
}
