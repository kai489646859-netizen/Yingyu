/// Read independent in-memory properties together. Missing diagnostics share
/// one bounded wait instead of adding up to eleven sequential timeouts.
/// This never reads media and does not apply color or decoder settings.
Future<Map<String, String>> openingOutputProperties(
  Future<String> Function(String) read, {
  required bool Function() active,
}) async {
  const keys = [
    'video-format',
    'video-params/primaries',
    'video-params/gamma',
    'video-params/colormatrix',
    'video-params/pixelformat',
    'hwdec-current',
    'audio-codec-name',
    'audio-params/channels',
    'audio-out-params/channels',
    'audio-out-params/format',
    'current-tracks/video/dolby-vision-profile',
  ];
  if (!active()) return {};
  final values = await Future.wait(
    keys.map((key) async {
      try {
        final value = await read(key).timeout(const Duration(seconds: 1));
        return !value.contains('://') &&
                RegExp(r'^[A-Za-z0-9_. +()/:-]{1,100}$').hasMatch(value)
            ? value
            : '未提供';
      } catch (_) {
        return '未提供';
      }
    }),
  );
  if (!active()) return {};
  return Map.fromIterables(keys, values);
}
