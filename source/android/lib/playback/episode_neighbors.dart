import '../core/emby.dart';
import '../core/models.dart';
import '../core/browse_cache.dart';

class EpisodeNeighbors {
  const EpisodeNeighbors({this.previous, this.next, this.warning});
  final String? warning;
  final MediaItem? previous, next;

  static Future<EpisodeNeighbors> load(
    EmbyClient api,
    MediaItem current, {
    BrowseRepository? browse,
    bool Function()? allowed,
    void Function(MediaItem, bool)? onCurrent,
  }) async {
    final account = api.session;
    void check() {
      if (account == null ||
          api.session != account ||
          allowed?.call() == false) {
        throw const AppFailure('相邻分集请求已失效');
      }
    }

    check();
    final seriesId = current.data['SeriesId']?.toString() ?? '';
    if (current.type != 'Episode' || seriesId.isEmpty) {
      return const EpisodeNeighbors();
    }
    final seasonId = current.data['SeasonId']?.toString() ?? '';
    final seasonNumber = number(current.data['ParentIndexNumber']);
    List<MediaItem>? cached(String key) {
      if (browse == null || !browse.current || browse.api != api) return null;
      final record = browse.peek(key);
      if (record == null || record.total != record.items.length) return null;
      return record.items;
    }

    Future<void> remember(String key, ItemPage page) async {
      check();
      if (browse == null || !browse.current || browse.api != api) return;
      try {
        await browse.cache.put(browse.key(key), page, browse.now());
      } catch (_) {
        /* Cache storage failure must not prevent an accepted switch. */
      }
      check();
    }

    List<MediaItem>? catalogue(String id) => ordered(
      cached(BrowseRepository.episodeCatalogueKey(seriesId, id)),
      seriesId,
      id,
    );
    List<MediaItem>? seasonList = cached('seasons:$seriesId');
    Future<MediaItem?> across(int direction) async {
      if (seasonNumber == null || seasonNumber < 1) return null;
      final targetNumber = seasonNumber + direction;
      if (targetNumber < 1) return null;
      if (seasonList == null) {
        check();
        final page = await api.seasons(seriesId);
        check();
        if (!page.countKnown || page.total != page.items.length) {
          throw const AppFailure('季目录返回不完整，请重新选集');
        }
        seasonList = page.items;
        await remember('seasons:$seriesId', page);
      }
      final targets = seasonList!.where(
        (item) =>
            item.type == 'Season' &&
            item.id.isNotEmpty &&
            number(item.data['IndexNumber']) == targetNumber &&
            (item.data['SeriesId'] == null ||
                item.data['SeriesId'] == seriesId),
      );
      // Never jump over a missing season or guess between duplicate seasons.
      if (targets.length != 1) return null;
      final target = targets.single;
      final boundaryKey =
          'episode-boundary:v1:$seriesId:${target.id}:$direction';
      final local =
          catalogue(target.id) ??
          ordered(cached(boundaryKey), seriesId, target.id);
      List<MediaItem> values;
      if (local != null) {
        values = local;
      } else {
        check();
        final response = await api.api(
          'Shows/$seriesId/Episodes',
          query: {
            'UserId': account!.userId,
            'SeasonId': target.id,
            'StartIndex': '0',
            'Limit': '1',
            'SortBy': 'IndexNumber',
            'SortOrder': direction > 0 ? 'Ascending' : 'Descending',
            'Fields': 'SeriesPrimaryImageTag',
          },
        );
        check();
        final page = ItemPage.fromJson(response);
        values = page.items;
        if (!page.countKnown ||
            values.length > 1 ||
            values.isEmpty && page.total > 0) {
          throw const AppFailure('分集边界返回异常');
        }
        if (values.every((item) => valid(item, seriesId, target.id))) {
          await remember(boundaryKey, ItemPage(values, values.length));
        }
      }
      if (values.isEmpty) return null;
      final item = direction > 0 ? values.first : values.last;
      if (!valid(item, seriesId, target.id) ||
          number(item.data['ParentIndexNumber']) != targetNumber ||
          (direction > 0 && number(item.data['IndexNumber']) != 1)) {
        return null;
      }
      return item;
    }

    String? warning;
    Future<MediaItem?> safeAcross(int direction) async {
      try {
        return await across(direction);
      } catch (error) {
        check();
        warning = '跨季目录读取失败：${safeError(error)}；可手动重新选集';
        return null;
      }
    }

    final local = seasonId.isEmpty ? null : catalogue(seasonId);
    final localAt = local?.indexWhere((item) => item.id == current.id) ?? -1;
    if (local != null && localAt >= 0 && seasonNumber != null) {
      if (onCurrent != null) {
        onCurrent(
          local[localAt],
          local.length >= 75 &&
              local.any(
                (item) => (number(item.data['IndexNumber']) ?? 0) >= 75,
              ),
        );
      }
      final previous = localAt > 0 ? local[localAt - 1] : await safeAcross(-1);
      final next = localAt + 1 < local.length
          ? local[localAt + 1]
          : await safeAcross(1);
      check();
      return EpisodeNeighbors(previous: previous, next: next, warning: warning);
    }
    check();
    final response = await api.api(
      'Shows/$seriesId/Episodes',
      query: {
        'UserId': api.session!.userId,
        'AdjacentTo': current.id,
        'Fields': 'Overview,SeriesPrimaryImageTag',
      },
    );
    check();
    final items = ItemPage.fromJson(response).items;
    final at = items.indexWhere((e) => e.id == current.id);
    if (at < 0) throw const AppFailure('服务器未返回当前集的相邻信息，可返回选集重试');
    if (items[at].data['SeriesId'] == seriesId) {
      onCurrent?.call(items[at], false);
    }
    MediaItem? sibling(int index) {
      if (index < 0 || index >= items.length) return null;
      final item = items[index];
      if (item.type != 'Episode' ||
          !item.playable ||
          item.data['IsMissing'] == true ||
          item.data['IsVirtualItem'] == true ||
          item.id.isEmpty ||
          item.id == current.id ||
          item.data['SeriesId']?.toString() != seriesId) {
        return null;
      }
      return item;
    }

    final previous = sibling(at - 1), next = sibling(at + 1);
    final hasNextRow = at + 1 < items.length;
    if (hasNextRow && next == null) {
      // Invalid/missing metadata is not evidence that the season has ended.
      // Keep the known previous episode without trying a different season.
      return EpisodeNeighbors(
        previous: previous,
        warning: '下一集资料无效或资源缺失，可返回选集重试',
      );
    }
    final nextNumber = number(next?.data['ParentIndexNumber']);
    final crosses =
        next != null &&
        (nextNumber != null && nextNumber != seasonNumber ||
            seasonId.isNotEmpty &&
                next.data['SeasonId'] != null &&
                next.data['SeasonId'] != seasonId);
    final resolved =
        seasonNumber != null && seasonNumber > 0 && (!hasNextRow || crosses)
        ? await safeAcross(1)
        : next;
    check();
    return EpisodeNeighbors(
      previous: previous,
      next: resolved,
      warning: warning,
    );
  }

  static int? number(Object? value) =>
      value is int && value >= 0 ? value : null;
  static bool valid(MediaItem item, String series, String season) =>
      item.type == 'Episode' &&
      item.playable &&
      item.id.isNotEmpty &&
      item.data['SeriesId'] == series &&
      item.data['SeasonId'] == season &&
      item.data['IsMissing'] != true &&
      item.data['IsVirtualItem'] != true;

  static List<MediaItem>? ordered(
    List<MediaItem>? items,
    String series,
    String season,
  ) {
    if (items == null ||
        items.any(
          (item) =>
              !valid(item, series, season) ||
              number(item.data['IndexNumber']) == null,
        )) {
      return null;
    }
    final values = List<MediaItem>.of(items)
      ..sort(
        (a, b) => number(
          a.data['IndexNumber'],
        )!.compareTo(number(b.data['IndexNumber'])!),
      );
    if (values.map((item) => item.data['IndexNumber']).toSet().length !=
            values.length ||
        values.map((item) => item.id).toSet().length != values.length) {
      return null;
    }
    return values;
  }
}
