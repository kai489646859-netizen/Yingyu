import 'models.dart';

class UnplayedSeries extends MediaItem {
  UnplayedSeries(MediaItem episode, int count)
    : super({
        'Id': episode.data['SeriesId'],
        'Type': 'Series',
        'IsFolder': true,
        'Name': episode.data['SeriesName'] ?? '剧集',
        'ImageTags': {'Primary': episode.data['SeriesPrimaryImageTag'] ?? ''},
        'Overview': '已加载 $count 集未看 · 点按查看剧集',
      });
}

class PlayedSeries extends MediaItem {
  PlayedSeries(MediaItem episode, int count)
    : super({
        'Id': episode.data['SeriesId'],
        'Type': 'Series',
        'IsFolder': true,
        'Name': episode.data['SeriesName'] ?? '剧集',
        'ImageTags': {'Primary': episode.data['SeriesPrimaryImageTag'] ?? ''},
        'Overview': '已加载 $count 集已看记录 · 点按查看剧集',
      });
}

/// One display entry per explicit Emby SeriesId. Episode watch flags remain on
/// the original items; a partially watched season is never marked fully seen.
List<MediaItem> groupPlayed(Iterable<MediaItem> items) {
  final rows = items.toList();
  final episodes = <String, Set<String>>{};
  final parents = <String, MediaItem>{};
  for (final item in rows) {
    final series = item.data['SeriesId']?.toString().trim() ?? '';
    if (item.type == 'Episode' && series.isNotEmpty) {
      (episodes[series] ??= {}).add(item.id);
    } else if (item.series && item.id.isNotEmpty) {
      parents[item.id] = item;
    }
  }
  final seen = <String>{};
  final grouped = <MediaItem>[];
  for (final item in rows) {
    final series = item.data['SeriesId']?.toString().trim() ?? '';
    if (item.type == 'Episode' && series.isNotEmpty) {
      if (seen.add('series:$series')) {
        grouped.add(
          parents[series] ?? PlayedSeries(item, episodes[series]!.length),
        );
      }
    } else if (seen.add('${item.series ? 'series' : 'item'}:${item.id}')) {
      grouped.add(item);
    }
  }
  return grouped;
}

/// Display projection only, scoped by the caller's account. Unknown series IDs
/// stay independent; never use titles/TMDB IDs or move episode state to a series.
List<MediaItem> groupUnplayed(Iterable<MediaItem> items) {
  final episodes = <String, List<MediaItem>>{};
  for (final item in items) {
    final series = item.data['SeriesId']?.toString() ?? '';
    if (item.type == 'Episode' && series.isNotEmpty) {
      (episodes[series] ??= []).add(item);
    }
  }
  final seen = <String>{};
  return [
    for (final item in items)
      if (item.type != 'Episode' ||
          (item.data['SeriesId']?.toString() ?? '').isEmpty)
        item
      else if (seen.add(item.data['SeriesId'].toString()))
        UnplayedSeries(
          item,
          episodes[item.data['SeriesId'].toString()]!.length,
        ),
  ];
}
