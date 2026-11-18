import 'models.dart';

/// Resolution from structured dimensions only.
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
  return switch ('${video['ExtendedVideoType'] ?? ''}'.trim().toLowerCase()) {
    'hdr10' => 'HDR10',
    'hdr10plus' => 'HDR10+',
    'hyperloggamma' => 'HLG',
    _ => '',
  };
}

String videoPixelLabel(Json video) {
  final width = integer(video['Width']), height = integer(video['Height']);
  if (width > 0 && height > 0) return '$width×$height';
  if (width > 0) return '宽 $width px';
  if (height > 0) return '高 $height px';
  return '';
}

String videoCodecLabel(Json video) =>
    switch ('${video['Codec'] ?? ''}'.trim().toLowerCase()) {
      'avc' || 'avc1' || 'h264' => 'H264',
      'hevc' || 'h265' || 'hvc1' || 'hev1' => 'HEVC',
      'av1' || 'av01' => 'AV1',
      'vp8' => 'VP8',
      'vp9' || 'vp09' => 'VP9',
      'mpeg2video' => 'MPEG-2',
      'vc1' => 'VC-1',
      'vvc' || 'h266' || 'vvc1' => 'VVC',
      final codec
          when RegExp(r'^[a-z0-9][a-z0-9_-]{0,19}$').hasMatch(codec) &&
              codec != 'unknown' =>
        codec.toUpperCase(),
      _ => '',
    };

String mediaSourceFacts(Json source) {
  final video =
      objects(
        source['MediaStreams'],
      ).where((stream) => stream['Type'] == 'Video').firstOrNull ??
      {};
  final size = integer(source['Size']);
  return [
    videoResolutionLabel(video),
    videoPixelLabel(video),
    videoRangeLabel(video),
    if (size > 0) '${(size / 1000000000).toStringAsFixed(2)} GB',
    videoCodecLabel(video),
  ].where((value) => value.isNotEmpty).join(' · ');
}

const versionHintsKey = '_YingyuVersionHintsV1';
const _resolutionNames = {
  '1k': '1080p',
  '8k': '8K',
  '4320p': '8K',
  '4k': '4K',
  '2160p': '4K',
  'uhd': '4K',
  '2k': '2K',
  '1440p': '2K',
  '1080p': '1080p',
  '1080i': '1080p',
  '720p': '720p',
  '576p': '576p',
  '540p': '540p',
  '480p': '480p',
  '360p': '360p',
};
const _visibleResolutionTiers = {'720p', '1080p', '4K'};
const _rangeNames = {
  'dolbyvision': '杜比视界',
  'dovi': '杜比视界',
  'dv': '杜比视界',
  'dvhe': '杜比视界',
  'dvh1': '杜比视界',
  'hdr10plus': 'HDR10+',
  'hdr10': 'HDR10',
  'hlg': 'HLG',
  'hdr': 'HDR',
  'sdr': 'SDR',
};
const _codecNames = {
  'hevc': 'HEVC',
  'h265': 'HEVC',
  'x265': 'HEVC',
  'h264': 'H264',
  'x264': 'H264',
  'avc': 'H264',
  'av1': 'AV1',
  'vp9': 'VP9',
  'vvc': 'VVC',
  'h266': 'VVC',
};

/// Keep only recognized tokens from this version's name or filename.
/// Never display or persist a path as part of the inferred format.
Json versionNameHints(Json source) {
  final saved = object(source[versionHintsKey]);
  final path = source['Path'];
  final savedResolution =
      _resolutionNames['${saved['resolution']}'.toLowerCase()];
  return {
    'resolution': ?savedResolution,
    if (_rangeNames.containsValue(saved['range'])) 'range': saved['range'],
    if (_codecNames.containsValue(saved['codec'])) 'codec': saved['codec'],
    if (path is String)
      ..._readVersionName(
        path.split(RegExp(r'[?#]')).first.split(RegExp(r'[/\\]')).last,
      ),
    if (source['Name'] case final String name) ..._readVersionName(name),
  };
}

final _namedDimensions = RegExp(
  r'(?<![0-9])(\d{3,5})\s*[x×]\s*(\d{3,5})(?![0-9])',
  caseSensitive: false,
);

/// Canonical browsing tiers, including cropped widescreen at a standard width.
String _resolutionTier(int width, int height) {
  final long = width > height ? width : height;
  final short = width < height ? width : height;
  if ((long >= 7600 && long <= 8192) || short == 4320) return '8K';
  if (long >= 3800 && long <= 4096) return '4K';
  if (long == 2048 || long == 2560 || (long <= 2560 && short == 1440)) {
    return '2K';
  }
  if (long == 1920 || (long < 2048 && short == 1080)) return '1080p';
  if (long == 1280 || (long < 1920 && short == 720)) return '720p';
  if (const {576, 540, 480, 360}.contains(short)) return '${short}p';
  return '';
}

Json _readVersionName(String name) {
  final tokens = name
      .toLowerCase()
      .replaceAll(RegExp(r'dolby[ ._-]+vision'), 'dolbyvision')
      .replaceAll(RegExp(r'hdr10\s*\+'), 'hdr10plus')
      .split(RegExp(r'[^a-z0-9]+'));
  final resolutions = tokens
      .map((word) => _resolutionNames[word])
      .nonNulls
      .toSet();
  if (resolutions.isEmpty) {
    resolutions.addAll(
      _namedDimensions
          .allMatches(name)
          .map(
            (match) => _resolutionTier(
              int.parse(match.group(1)!),
              int.parse(match.group(2)!),
            ),
          )
          .where((label) => label.isNotEmpty),
    );
  }
  final codecs = tokens.map((word) => _codecNames[word]).nonNulls.toSet();
  final ranges = tokens.map((word) => _rangeNames[word]).nonNulls.toSet();
  for (var i = 1; i < tokens.length; i++) {
    if (!_rangeNames.containsKey(tokens[i - 1]) &&
        !_resolutionNames.containsKey(tokens[i - 1])) {
      continue;
    }
    if (tokens[i] == '265') codecs.add('HEVC');
    if (tokens[i] == '264') codecs.add('H264');
  }
  final range = const [
    '杜比视界',
    'HDR10+',
    'HDR10',
    'HLG',
    'HDR',
    'SDR',
  ].where(ranges.contains).firstOrNull;
  return {
    if (resolutions.length == 1) 'resolution': resolutions.single,
    'range': ?range,
    if (codecs.length == 1) 'codec': codecs.single,
  };
}

String _hint(Json video, String field) {
  final value = object(video[versionHintsKey])[field];
  final allowed = switch (field) {
    'resolution' => _resolutionNames.values,
    'range' => _rangeNames.values,
    _ => _codecNames.values,
  };
  return value is String && allowed.contains(value) ? value : '';
}

String resourceCodecLabel(Json video) {
  final named = _hint(video, 'codec');
  return named.isEmpty ? videoCodecLabel(video) : named;
}

bool usesVersionNameHint(Json video, {bool includeCodec = false}) =>
    _visibleResolutionTiers.contains(_hint(video, 'resolution')) ||
    _hint(video, 'range').isNotEmpty ||
    (includeCodec && _hint(video, 'codec').isNotEmpty);

Json resourceVideo(MediaItem item, {String? sourceId}) {
  final sources = objects(item.data['MediaSources']);
  final source = sourceId == null
      ? sources.firstOrNull
      : sources.where((s) => s['Id']?.toString() == sourceId).firstOrNull;
  if (sourceId != null && source == null) return {};
  final streams = objects(source?['MediaStreams']);
  final video =
      (streams.isNotEmpty
              ? streams
              : sources.length <= 1
              ? objects(item.data['MediaStreams'])
              : <Json>[])
          .where((s) => s['Type'] == 'Video')
          .firstOrNull ??
      {};
  final hints = {
    if (sources.length <= 1) ...versionNameHints(item.data),
    if (source != null) ...versionNameHints(source),
  };
  return hints.isEmpty ? video : {...video, versionHintsKey: hints};
}

List<String> resourceLabels(Json video) {
  final namedRange = _hint(video, 'range');
  final range = namedRange.isEmpty ? videoRangeLabel(video) : namedRange;
  final namedResolution = _hint(video, 'resolution');
  final resolution = namedResolution.isEmpty
      ? _resolutionTier(integer(video['Width']), integer(video['Height']))
      : namedResolution;
  return [
    if (_visibleResolutionTiers.contains(resolution)) resolution.toUpperCase(),
    if (range.startsWith('杜比视界'))
      '杜比'
    else if (range != 'SDR' || namedRange.isNotEmpty)
      range,
  ].where((s) => s.isNotEmpty).toList();
}

String resourceName(Json video) {
  final labels = resourceLabels(video);
  return labels.isEmpty ? '格式未知' : labels.join(' ');
}
