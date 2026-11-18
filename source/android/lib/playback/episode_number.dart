import '../core/models.dart';

/// The ordinal must be explicit. A catalogue's row index is not an episode number.
int playbackEpisodeNumber(MediaItem item) {
  final number = integer(item.data['IndexNumber']);
  if (number > 0) return number;
  final filename = item.data['Path']?.toString().split(RegExp(r'[/\\]')).last;
  for (final label in [item.title, ?filename]) {
    final numbers = episodeOrdinalsIn(label);
    if (numbers.length > 1) return 0;
    if (numbers.length == 1) return numbers.single;
  }
  return 0;
}
