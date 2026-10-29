import '../core/emby.dart';
import '../core/models.dart';

class EpisodeNeighbors {
  const EpisodeNeighbors({this.previous, this.next});
  final MediaItem? previous, next;

  static Future<EpisodeNeighbors> load(
    EmbyClient api,
    MediaItem current,
  ) async {
    final seriesId = current.data['SeriesId']?.toString() ?? '';
    if (current.type != 'Episode' || seriesId.isEmpty) {
      return const EpisodeNeighbors();
    }
    final response = await api.api(
      'Shows/$seriesId/Episodes',
      query: {
        'UserId': api.session!.userId,
        'AdjacentTo': current.id,
        'Fields': 'Overview,SeriesPrimaryImageTag',
      },
    );
    final items = ItemPage.fromJson(response).items;
    final at = items.indexWhere((e) => e.id == current.id);
    if (at < 0) throw const AppFailure('服务器未返回当前集的相邻信息，可返回选集重试');
    MediaItem? sibling(int index) {
      if (index < 0 || index >= items.length) return null;
      final item = items[index];
      if (item.type != 'Episode' ||
          !item.playable ||
          item.id.isEmpty ||
          item.id == current.id ||
          item.data['SeriesId']?.toString() != seriesId) {
        return null;
      }
      return item;
    }

    return EpisodeNeighbors(previous: sibling(at - 1), next: sibling(at + 1));
  }
}
