/// Read-only facts for the information panel. Packet bitrates describe media
/// time (not download speed); MPV documents them as estimates, not file averages.
abstract class PlaybackFactsBackend {
  PlaybackMediaFacts get mediaFacts;
}

abstract class PlaybackResourceBackend {
  /// Confirmed by the active disc transport, including detected STRM targets.
  String get discResourceType;
}

class PlaybackMediaFacts {
  const PlaybackMediaFacts([this.values = const {}]);
  final Map<String, String> values;
  String? operator [](String key) => values[key];
}

const mediaFactProperties = [
  'video-format',
  'file-format',
  'video-codec',
  'video-bitrate',
  'video-params/w',
  'video-params/h',
  'video-params/pixelformat',
  'video-params/primaries',
  'video-params/gamma',
  'video-params/colormatrix',
  'video-params/colorlevels',
  'current-tracks/video/dolby-vision-profile',
  'current-tracks/video/dolby-vision-level',
  'container-fps',
  'hwdec-current',
  'audio-codec-name',
  'audio-bitrate',
  'audio-params/samplerate',
  'audio-params/channels',
  'audio-out-params/channels',
];

PlaybackMediaFacts readPlaybackMediaFacts({
  required String Function(String) read,
  required bool Function() active,
}) {
  String value(String key) {
    try {
      final result = read(key);
      // These properties contain only codec/format names and numeric values.
      if (result.length <= 160 &&
          RegExp(r'^[A-Za-z0-9 ._+()/,:-]+$').hasMatch(result)) {
        return result;
      }
    } catch (_) {
      /* Unsupported facts remain unknown. */
    }
    return '';
  }

  const identity = ['vid', 'aid', 'seeking'];
  final before = identity.map(value).toList();
  if (!active() || before[2] != 'no') return const PlaybackMediaFacts();
  final facts = mediaFactProperties.map(value).toList();
  final after = identity.map(value).toList();
  if (!active() || before.join('|') != after.join('|') || after[2] != 'no') {
    return const PlaybackMediaFacts();
  }
  return PlaybackMediaFacts(
    Map.unmodifiable({
      'vid': before[0],
      'aid': before[1],
      for (var i = 0; i < facts.length; i++)
        if (facts[i].isNotEmpty) mediaFactProperties[i]: facts[i],
    }),
  );
}

String mediaBitrate(Object? value) {
  final bits = double.tryParse('$value');
  if (bits == null || !bits.isFinite || bits <= 0) return '未提供';
  return bits >= 1000000
      ? '${(bits / 1000000).toStringAsFixed(2)} Mbps'
      : '${(bits / 1000).toStringAsFixed(1)} kbps';
}
