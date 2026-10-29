import '../core/models.dart';
import 'dolby_source.dart';

String? _actual(Map<String, String> decoded, String key) {
  final value = decoded[key];
  return value == null || value.isEmpty || value == '未提供' ? null : value;
}

int? _profile(Object? value) {
  final number = value is num && value.isFinite && value == value.toInt()
      ? value.toInt()
      : value is String
      ? int.tryParse(value)
      : null;
  return number != null && number > 0 && number <= 10 ? number : null;
}

/// Source video format from the current track, with unambiguous structured
/// server metadata as a fallback. This does not describe the display output.
String sourceVideoFormat({
  required List<Json> streams,
  Map<String, String> decoded = const {},
  bool allowServerFallback = true,
}) {
  final actualProfile =
      _profile(_actual(decoded, 'current-tracks/video/dolby-vision-profile')) ??
      _profile(_actual(decoded, 'dolby-vision-profile'));
  if (actualProfile != null) return '杜比视界 Profile $actualProfile';
  if (_actual(decoded, 'video-params/colormatrix') == 'dolbyvision') {
    // A server profile may describe a different edit/track. Do not attach it
    // to a current track whose Dolby matrix is known but profile is unavailable.
    return '杜比视界';
  }
  final videos = streams.where((s) => s['Type'] == 'Video').toList();
  final video = allowServerFallback && videos.length == 1
      ? videos.single
      : const <String, dynamic>{};
  // Emby exposes source HDR formats in ExtendedVideoType/SubType. These are
  // structured fields; file names and free-form display titles are not evidence.
  final extended = '${video['ExtendedVideoType'] ?? ''}'.toLowerCase();
  final subtype =
      '${video['ExtendedVideoSubType'] ?? video['ExtendedVideoSubtype'] ?? ''}'
          .toLowerCase();
  const doviProfiles = {
    'doviprofile10': 1,
    'doviprofile22': 2,
    'doviprofile30': 3,
    'doviprofile42': 4,
    'doviprofile50': 5,
    'doviprofile61': 6,
    'doviprofile76': 7,
    'doviprofile81': 8,
    'doviprofile82': 8,
    'doviprofile83': 8,
    'doviprofile84': 8,
    'doviprofile85': 8,
    'doviprofile92': 9,
  };
  final profile =
      (video['DoviProfile'] is num ? _profile(video['DoviProfile']) : null) ??
      (video['DvProfile'] is num ? _profile(video['DvProfile']) : null) ??
      doviProfiles[subtype];
  final range = '${video['VideoRange'] ?? ''} ${video['VideoRangeType'] ?? ''}'
      .toLowerCase();
  final markedVideo = Map<String, dynamic>.of(video)
    ..remove('DoviProfile')
    ..remove('DvProfile');
  final dolby =
      requestsDolbyMapping([markedVideo]) ||
      profile != null ||
      extended == 'dolbyvision' ||
      subtype == 'doviprofile02' ||
      range.contains('dolbyvision') ||
      range.contains('dolby vision');
  if (dolby) return '杜比视界${profile == null ? '' : ' Profile $profile'}';
  // A PQ/HLG base layer cannot exclude Dolby Vision. Once Dolby evidence has
  // been considered, an actual transfer wins over a conflicting server label.
  final actualGamma = _actual(decoded, 'video-params/gamma')?.toLowerCase();
  if (const {'hlg', 'arib-std-b67'}.contains(actualGamma)) return 'HLG';
  if (const {'pq', 'smpte2084'}.contains(actualGamma)) return 'HDR';
  final gamma = '${video['ColorTransfer'] ?? ''}'.toLowerCase();
  final hdr =
      const {'pq', 'smpte2084'}.contains(gamma) ||
      range.contains('hdr') ||
      const {'hdr10', 'hdr10plus'}.contains(extended);
  final hlg =
      const {'hlg', 'arib-std-b67'}.contains(gamma) ||
      range.contains('hlg') ||
      extended == 'hyperloggamma';
  return hlg
      ? 'HLG'
      : hdr
      ? 'HDR'
      : '';
}

/// Primary user-facing message describes the established picture route. Audio
/// codec branding stays in the information panel and cannot imply Dolby video.
String mediaNotice({
  required bool bluray,
  required List<Json> streams,
  Map<String, String> decoded = const {},
  bool nativeHdr = false,
  bool? dolbyMapped,
  String? currentGamma,
  String? currentMatrix,
}) {
  final current = <String, String>{
    ...decoded,
    if (_actual(decoded, 'video-params/gamma') == null &&
        const [
          'bt.1886',
          'bt.709',
          'gamma2.2',
          'gamma2.4',
          'srgb',
          'linear',
        ].contains(currentGamma?.toLowerCase()))
      'video-params/gamma': currentGamma!.toLowerCase(),
    if (const {
      'pq',
      'hlg',
      'smpte2084',
      'arib-std-b67',
    }.contains(currentGamma?.toLowerCase()))
      'video-params/gamma': currentGamma!.toLowerCase(),
    // A base layer's ordinary matrix is not evidence against Dolby Vision.
    if (currentMatrix == 'dolbyvision')
      'video-params/colormatrix': currentMatrix!,
  };
  final videoFormat = sourceVideoFormat(streams: streams, decoded: current);
  String output;
  if (nativeHdr) {
    final transfer = _actual(current, 'video-params/gamma')?.toLowerCase();
    output =
        '${const {'hlg', 'arib-std-b67'}.contains(transfer) ? 'HLG' : 'HDR10'} · 高动态范围';
  } else if ((dolbyMapped ?? videoFormat.startsWith('杜比视界')) ||
      videoFormat.isNotEmpty) {
    output = videoFormat.startsWith('杜比视界')
        ? 'Dolby Vision · 杜比视界 → SDR · 色彩适配'
        : 'SDR · 已做色彩适配';
  } else if (const {
    'bt.1886',
    'bt.709',
    'gamma2.2',
    'gamma2.4',
    'srgb',
    'linear',
  }.contains(_actual(current, 'video-params/gamma')?.toLowerCase())) {
    output = 'SDR · 标准动态范围';
  } else {
    // An actual parsed disc is enough to describe its container, never HDR.
    return bluray ? '蓝光原盘' : '';
  }
  return '$output${bluray ? ' · 蓝光原盘' : ''}';
}

String sourceFormatLabel(String value) =>
    value.replaceFirst('杜比视界', 'Dolby Vision · 杜比视界');
