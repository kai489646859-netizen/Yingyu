/// Yingyu's limited adapter for the pinned 2.0.1 Android surface lifecycle.
/// An initial surface has no old frame to refresh. A cleanup must never seek.
/// For a replacement, preserve MPV's in-flight resume/seek and read the native
/// clock instead of media_kit's asynchronously updated (possibly zero) state.
Future<void> updateAndroidSurface({
  required int wid,
  required int width,
  required int height,
  required String output,
  required Future<String> Function(String) read,
  required Future<void> Function(String, String) write,
  required Future<void> Function(Duration) seek,
}) async {
  var hadFrame = false;
  if (wid != 0) {
    try {
      hadFrame = const {
        'yes',
        'no',
      }.contains(await read('video-frame-info/interlaced'));
    } catch (_) {
      // A missing frame/property during initialization cannot require a seek.
    }
  }
  // Preserve the upstream ordering and zero-surface crash guard.
  await write('vo', 'null');
  await write('android-surface-size', '${width}x$height');
  await write('wid', '$wid');
  await write('vo', wid == 0 ? 'null' : output);
  if (output == 'mediacodec_embed') {
    await write('vid', wid == 0 ? 'no' : 'auto');
  }
  if (wid == 0 || !hadFrame) return;
  Duration? position;
  try {
    if (await read('seeking') != 'no' || await read('idle-active') != 'no') {
      return;
    }
    final seconds = double.tryParse(await read('time-pos'));
    if (seconds != null && seconds.isFinite && seconds >= 0 && seconds < 1e9) {
      position = Duration(microseconds: (seconds * 1000000).round());
    }
  } catch (_) {
    // Do not turn an unavailable clock into an unsolicited seek to zero.
  }
  if (position != null) await seek(position);
}
