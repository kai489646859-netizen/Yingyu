/// Prepare only an unambiguous, already parsed video before decoder startup.
/// on_preloaded runs before MPV selects current-tracks, so inspect the explicit
/// vid or the sole non-image video. Unknown/multiple videos keep the old path.
Future<bool> prepareOpenedVideoSurface({
  required String address,
  required Future<String> Function(String) read,
  required Future<bool> Function(int, int) prepare,
  required bool Function() active,
}) async {
  if (!active()) return false;
  try {
    if (await read('path') != address || !active()) return false;
    final selected = await read('vid');
    if (!active() || selected == 'no') return false;
    final explicit = int.tryParse(selected);
    if (selected != 'auto' && (explicit == null || explicit <= 0)) return false;
    final count = int.tryParse(await read('track-list/count'));
    if (!active() || count == null || count <= 0 || count > 64) return false;
    String? track;
    String? trackId;
    for (var i = 0; i < count; i++) {
      final key = 'track-list/$i';
      if (!active()) return false;
      if (await read('$key/type') != 'video') continue;
      final id = await read('$key/id');
      if (explicit != null && id != selected) continue;
      if (await read('$key/image') != 'no' ||
          await read('$key/albumart') != 'no') {
        return false;
      }
      if (track != null) return false;
      track = key;
      trackId = id;
    }
    if (track == null) return false;
    var width = int.tryParse(await read('$track/demux-w'));
    var height = int.tryParse(await read('$track/demux-h'));
    // Fixed MPV marks rotation=0 unavailable. Other failures remain optional.
    String rotation;
    try {
      rotation = await read('$track/demux-rotation');
    } catch (_) {
      rotation = '0';
    }
    // NativePlayer's synchronous getter returns an empty string (not an
    // exception) for the pinned MPV's unavailable zero-rotation property.
    final angle = rotation.isEmpty ? 0 : int.tryParse(rotation);
    if (angle == null) return false;
    if (!const {0, 90, 180, 270}.contains(angle)) return false;
    if (angle == 90 || angle == 270) {
      final saved = width;
      width = height;
      height = saved;
    }
    if (width == null ||
        height == null ||
        width < 2 ||
        height < 2 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 33554432) {
      return false;
    }
    if (!active() ||
        await read('path') != address ||
        await read('vid') != selected ||
        await read('$track/id') != trackId ||
        !active()) {
      return false;
    }
    return await prepare(width, height) && active();
  } catch (_) {
    // This optional pre-decoder optimization never replaces real output/frame
    // checks or suppresses a failure from the normal decoder startup path.
    return false;
  }
}
