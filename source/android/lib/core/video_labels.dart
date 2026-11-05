import 'models.dart';

/// Presentation only: structured metadata, never filenames or media probes.
String videoResolutionLabel(Json video) {
  final width = integer(video['Width']), height = integer(video['Height']);
  if (width <= 0 || height <= 0) return '';
  final long = width > height ? width : height;
  final short = width < height ? width : height;
  return long >= 7600 || short >= 4200
      ? '8K'
      : long >= 3800 || short >= 2100
      ? '4K'
      : long >= 2500 || short >= 1400
      ? '1440p'
      : long >= 1900 || short >= 1000
      ? '1080p'
      : '${short}p';
}

String videoRangeLabel(Json video) {
  final profiles = [
    'DoviProfile',
    'DvProfile',
    'DolbyVisionProfile',
  ].map((key) => integer(video[key]));
  final profile = profiles.where((p) => p > 0 && p <= 10).firstOrNull;
  final ranges = ['VideoRangeType', 'VideoRange']
      .map((key) => '${video[key] ?? ''}'.trim().toLowerCase())
      .where((value) => value.isNotEmpty);
  final dolby =
      profile != null ||
      '${video['ExtendedVideoType'] ?? ''}'.toLowerCase() == 'dolbyvision' ||
      ranges.any(
        const {
          'dv',
          'dovi',
          'dolbyvision',
          'dolby vision',
          'doviwithhdr10',
          'doviwithelhdr10',
          'doviwithhdr10plus',
          'doviwithelhdr10plus',
          'doviwithhlg',
          'doviwithsdr',
        }.contains,
      );
  if (dolby) return profile == null ? '杜比视界' : '杜比视界 P$profile';
  for (final range in ranges) {
    final label = const {
      'hdr10plus': 'HDR10+',
      'hdr10+': 'HDR10+',
      'hdr10': 'HDR10',
      'hlg': 'HLG',
      'sdr': 'SDR',
      'hdr': 'HDR',
    }[range];
    if (label != null) return label;
  }
  return '';
}

String mediaSourceFacts(Json source) {
  final video =
      objects(
        source['MediaStreams'],
      ).where((stream) => stream['Type'] == 'Video').firstOrNull ??
      {};
  final width = integer(video['Width']), height = integer(video['Height']);
  final size = integer(source['Size']);
  return [
    videoResolutionLabel(video),
    if (width > 0 && height > 0) '$width×$height',
    videoRangeLabel(video),
    if (size > 0) '${(size / 1000000000).toStringAsFixed(2)} GB',
    if (video['Codec'] != null) '${video['Codec']}'.toUpperCase(),
  ].where((value) => value.isNotEmpty).join(' · ');
}

Json resourceVideo(MediaItem item, {String? sourceId}) {
  final sources = objects(item.data['MediaSources']);
  final source = sourceId == null
      ? sources.firstOrNull
      : sources.where((s) => s['Id'] == sourceId).firstOrNull;
  if (sourceId != null && source == null) return {};
  final streams = objects(source?['MediaStreams']);
  return (streams.isNotEmpty
              ? streams
              : sources.length <= 1
              ? objects(item.data['MediaStreams'])
              : <Json>[])
          .where((s) => s['Type'] == 'Video')
          .firstOrNull ??
      {};
}

List<String> resourceLabels(Json video) {
  final range = videoRangeLabel(video);
  return [
    videoResolutionLabel(video),
    if (range.startsWith('杜比视界')) '杜比' else if (range != 'SDR') range,
  ].where((s) => s.isNotEmpty).toList();
}

String resourceName(Json video) {
  final labels = resourceLabels(video);
  return labels.isEmpty ? '格式未知' : labels.join(' ');
}
