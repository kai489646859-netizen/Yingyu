import '../core/accounts.dart';
import '../core/models.dart';
import 'tracks.dart';

/// Owned by one player page only. Never writes a speed preference to storage.
class EpisodeContinuity {
  EpisodeContinuity({
    required this.account,
    required this.series,
    required this.speed,
    required Map<bool, TrackChoice?> choices,
  }) : choices = Map.unmodifiable(choices);
  final String account, series;
  final double speed;
  final Map<bool, TrackChoice?> choices;
  static String? seriesOf(MediaItem item) {
    final value = item.data['SeriesId']?.toString().trim();
    return item.type == 'Episode' && value != null && value.isNotEmpty
        ? value
        : null;
  }

  bool matches(Session user, MediaItem item) =>
      account == accountKey(user) && seriesOf(item) == series;
}
