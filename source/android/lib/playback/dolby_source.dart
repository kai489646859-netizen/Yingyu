import '../core/models.dart';

/// The demuxer has already opened this exact media. All reads are in-memory
/// properties, before decoder initialization; unknown does not mean non-Dolby.
Future<int?> prepareOpenedDolby({
  required String address,
  required Future<String> Function(String) read,
  required Future<void> Function() enable,
  required bool Function() active,
}) async {
  if (!active()) return null;
  final path = await read('path');
  if (!active() || path != address) return null;
  final profile = int.tryParse(
    await read('yingyu-preloaded-dolby-vision-profile'),
  );
  if (!active() || profile == null || profile <= 0 || profile > 10) return null;
  await enable();
  return active() ? profile : null;
}

enum DolbyOutputFailure { none, mapping, pairing, capability }

/// Exact fixed messages only: useful diagnostics without a path or URL.
String dolbyOutputFailureCode(String text) => switch (text.trim()) {
  'Dolby surface timestamp does not match codec output' => 'surface_timestamp',
  'Timed out matching a Dolby surface to its metadata' => 'surface_timeout',
  'Raw external YUV sampling is unavailable' => 'raw_yuv_capability',
  'Mapping hardware decoded surface failed.' => 'hardware_mapping',
  'Dolby metadata input cannot be paired safely' => 'metadata_input',
  'Dolby output metadata pairing failed' => 'metadata_output',
  _ => 'unknown',
};

/// Keep a generic mapper error distinct from a confirmed unsafe Dolby pair.
/// In the pinned stack an invalidated MediaCodec buffer also reaches that
/// generic message. Only an active, bounded seek recovery may retry it.
DolbyOutputFailure classifyDolbyOutputFailure(
  String prefix,
  String level,
  String text,
) {
  if (level != 'error') return DolbyOutputFailure.none;
  final message = text.trim();
  if (prefix == 'vo/gpu-next' || prefix.startsWith('vo/gpu-next/')) {
    if (const {
      'Dolby surface timestamp does not match codec output',
      'Timed out matching a Dolby surface to its metadata',
    }.contains(message)) {
      return DolbyOutputFailure.pairing;
    }
    if (message == 'Raw external YUV sampling is unavailable') {
      return DolbyOutputFailure.capability;
    }
    if (message == 'Mapping hardware decoded surface failed.') {
      return DolbyOutputFailure.mapping;
    }
  }
  if (RegExp(r'^ffmpeg/video(?:/|$)').hasMatch(prefix) &&
      const {
        'Dolby metadata input cannot be paired safely',
        'Dolby output metadata pairing failed',
      }.contains(message)) {
    return DolbyOutputFailure.pairing;
  }
  return DolbyOutputFailure.none;
}

/// Compatibility for callers asking about a definite unsafe output. Generic
/// mapping errors must be passed to DolbySeekRecovery, never silently ignored.
bool isDolbyOutputFailure(String prefix, String level, String text) =>
    switch (classifyDolbyOutputFailure(prefix, level, text)) {
      DolbyOutputFailure.pairing || DolbyOutputFailure.capability => true,
      _ => false,
    };

/// Use structured source fields already returned by playback preparation.
/// No title/path guessing and no extra HTTP probe.
bool requestsDolbyMapping(List<Json> streams) {
  final video = streams.where((s) => s['Type'] == 'Video').firstOrNull;
  if (video == null) return false;
  final profile = video['DoviProfile'] ?? video['DvProfile'];
  if (profile is num && profile > 0 && profile <= 10) return true;
  final extended = '${video['ExtendedVideoType'] ?? ''}'.toLowerCase();
  final subtype =
      '${video['ExtendedVideoSubType'] ?? video['ExtendedVideoSubtype'] ?? ''}'
          .toLowerCase();
  final ranges = [
    video['VideoRangeType'],
    video['VideoRange'],
  ].map((v) => '$v'.trim().toLowerCase());
  return extended == 'dolbyvision' ||
      RegExp(
        r'^doviprofile(?:02|10|22|30|42|50|61|76|81|82|83|84|85|92)$',
      ).hasMatch(subtype) ||
      ranges.any(
        const {
          'dolbyvision',
          'dolby vision',
          'dovi',
          'doviwithhdr10',
          'doviwithelhdr10',
          'doviwithhdr10plus',
          'doviwithelhdr10plus',
          'doviwithhlg',
          'doviwithsdr',
        }.contains,
      );
}
