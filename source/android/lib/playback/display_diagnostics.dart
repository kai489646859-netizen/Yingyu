/// A fixed native failure stage only. Never persist arbitrary native log text.
String? nativeHdrFailureStage(String text) {
  final match = RegExp(
    r'^Yingyu native HDR rejected: stage=([a-z0-9-]+); egl=([a-fA-F0-9]{1,8})\.$',
  ).firstMatch(text.trim());
  if (match == null ||
      !const {
        'window-token',
        'egl-display',
        'egl-extensions',
        'rgb10-context',
        'buffer-format',
        'dataspace-api',
        'dataspace-contract',
        'dataspace-library',
        'dataspace-symbols',
        'dataspace-set',
        'dataspace-readback',
        'egl-window',
        'egl-colorspace-current',
        'renderer',
      }.contains(match[1])) {
    return null;
  }
  return '${match[1]};egl=${match[2]!.toLowerCase()}';
}

/// Optional in-memory facts for comparing repeated opens. No writes, stream
/// reads, filenames, raw native messages or additional network requests.
Future<Map<String, String>> displayDiagnostics(
  Future<String> Function(String) read, {
  required bool Function() active,
}) async {
  const keys = [
    'video-params/gamma',
    'video-params/primaries',
    'video-params/sig-peak',
    'video-out-params/gamma',
    'video-out-params/primaries',
    'video-out-params/sig-peak',
    'video-target-params/gamma',
    'video-target-params/primaries',
    'video-target-params/sig-peak',
    'options/target-peak',
    'options/target-trc',
    'options/target-prim',
    'options/tone-mapping',
    'options/tone-mapping-param',
    'options/hdr-compute-peak',
    'hdr-metadata/max-luma',
    'hdr-metadata/max-pq-y',
    'hdr-metadata/avg-pq-y',
    'options/cache-on-disk',
    'options/cache-secs',
    'options/demuxer-max-bytes',
    'options/cache-pause-initial',
    'options/cache-pause-wait',
  ];
  if (!active()) return {};
  final values = await Future.wait(
    keys.map((key) async {
      try {
        final value = await read(
          key,
        ).timeout(const Duration(milliseconds: 600));
        return RegExp(r'^[a-zA-Z0-9_.+-]{1,32}$').hasMatch(value)
            ? value
            : '未提供';
      } catch (_) {
        return '未提供';
      }
    }),
  );
  return active() ? Map.fromIterables(keys, values) : {};
}

/// Color contract facts, not a screenshot or a physical luminance measurement.
Future<String?> colorDiagnostics(
  Future<String> Function(String) read, {
  required bool Function() active,
}) async {
  if (!active()) return null;
  const keys = [
    'video-params/colormatrix',
    'video-params/colorlevels',
    'video-dec-params/pixelformat',
    'video-dec-params/gamma',
    'video-dec-params/primaries',
    'video-out-params/pixelformat',
    'video-out-params/colorlevels',
    'video-target-params/gamma',
    'video-target-params/primaries',
    'options/video-output-levels',
    'options/brightness',
    'options/contrast',
    'options/gamma',
    'options/saturation',
    'options/target-peak',
    'options/tone-mapping',
  ];
  final fields = await Future.wait(
    keys.map((key) async {
      try {
        final value = await read(
          key,
        ).timeout(const Duration(milliseconds: 600));
        return '$key=${RegExp(r"^[a-zA-Z0-9_.+-]{1,32}$").hasMatch(value) ? value : "未提供"}';
      } catch (_) {
        return '$key=未提供';
      }
    }),
  );
  return active()
      ? '色彩契约核对：${fields.join("；")}；仅参数证据，不能据此认定偏色/偏灰/偏暗或屏幕亮度'
      : null;
}
