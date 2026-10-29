import 'catalog.dart';
import 'models.dart';

const catalogSortLabels = {
  'alphabet': '影片名称',
  'DateCreated': '添加时间',
  'PremiereDate': '上映时间',
  'CommunityRating': '影片评分',
};

String normalizeCatalogSort(String? value) => switch (value) {
  'ProductionYear' => 'PremiereDate',
  'DateCreated' || 'PremiereDate' || 'CommunityRating' => value!,
  _ => 'alphabet',
};

/// Refresh progress/ratings without sorting again if the active order's keys
/// are unchanged. Keeps UI filtering and scrolling out of the sort path.
class CatalogOrdering {
  String? _sort;
  bool? _descending;
  Map<String, (String, Object?)> _keys = {};
  List<MediaItem> _ordered = [];

  List<MediaItem> apply(List<MediaItem> items, String sort, bool descending) {
    final keys = {
      for (final item in items)
        item.id: (item.title, catalogSortValue(item, sort)),
    };
    if (_sort == sort &&
        _descending == descending &&
        keys.length == _keys.length &&
        keys.entries.every((entry) => _keys[entry.key] == entry.value)) {
      final byId = {for (final item in items) item.id: item};
      _ordered = [for (final item in _ordered) byId[item.id]!];
    } else {
      _ordered = orderCatalog((items, sort, descending));
    }
    _keys = keys;
    _sort = sort;
    _descending = descending;
    return _ordered;
  }
}

/// Release order follows the year shown in detail. Some servers provide only
/// ProductionYear, so a missing full premiere date must not erase that value.
num? catalogSortValue(MediaItem item, String sort) {
  if (sort == 'PremiereDate' || sort == 'ProductionYear') {
    final year = int.tryParse(item.year.trim());
    final date = DateTime.tryParse('${item.data['PremiereDate'] ?? ''}');
    if (year != null && year > 0 && year <= 9999) {
      return (date != null && date.year == year ? date : DateTime.utc(year))
          .toUtc()
          .millisecondsSinceEpoch;
    }
    return date != null && date.year > 0
        ? date.toUtc().millisecondsSinceEpoch
        : null;
  }
  if (sort == 'CommunityRating') {
    final rating = num.tryParse('${item.data[sort] ?? ''}');
    return rating?.isFinite == true ? rating : null;
  }
  if (sort == 'DateCreated') {
    return DateTime.tryParse(
      '${item.data[sort] ?? ''}',
    )?.toUtc().millisecondsSinceEpoch;
  }
  return null;
}

/// Reorder complete display metadata only. Never mutate the shared catalogue,
/// resolve media, or regenerate pinyin while changing direction or filtering.
List<MediaItem> orderCatalog((List<MediaItem>, String, bool) input) {
  final (items, sort, descending) = input;
  int titleCompare(MediaItem a, MediaItem b) {
    final left = object(a.data[titleKeysField]);
    final right = object(b.data[titleKeysField]);
    for (final key in ['letter', 'initials', 'title']) {
      final result = (left[key]?.toString() ?? a.title).compareTo(
        right[key]?.toString() ?? b.title,
      );
      if (result != 0) return result;
    }
    return a.id.compareTo(b.id);
  }

  // Parse once, including invalid/missing values. Unknown metadata stays last
  // in either direction; equal values use the existing deterministic name order.
  final values = sort == 'alphabet'
      ? const <String, num?>{}
      : {for (final item in items) item.id: catalogSortValue(item, sort)};
  return List<MediaItem>.of(items)..sort((a, b) {
    if (sort == 'alphabet') {
      final result = titleCompare(a, b);
      return descending ? -result : result;
    }
    final left = values[a.id], right = values[b.id];
    if (left == null || right == null) {
      if (left != null) return -1;
      if (right != null) return 1;
    } else {
      final result = left.compareTo(right);
      if (result != 0) return descending ? -result : result;
    }
    return titleCompare(a, b);
  });
}
