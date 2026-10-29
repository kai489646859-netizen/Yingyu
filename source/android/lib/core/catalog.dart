import 'package:pinyin/pinyin.dart';
import 'alphabet.dart';
import 'models.dart';
import 'broad_search.dart';

const titleKeysField = '_YingyuTitleKeysV1';

/// Called in a background isolate once when catalogue membership/titles change.
List<MediaItem> prepareServerCatalog(List<MediaItem> items) =>
    prepareCatalog(items, sort: false);

List<MediaItem> prepareCatalog(List<MediaItem> items, {bool sort = true}) {
  final ids = <String>{};
  final values = <MediaItem>[];
  for (final item in items) {
    if (!ids.add(item.id)) continue;
    final cached = object(item.data[titleKeysField]);
    if (cached['title'] == item.title) {
      values.add(item);
      continue;
    }
    String full;
    try {
      full = PinyinHelper.getPinyinE(
        item.title,
        separator: '',
        format: PinyinFormat.WITHOUT_TONE,
      ).toUpperCase();
    } catch (_) {
      full = item.title.toUpperCase();
    }
    values.add(
      MediaItem({
        ...item.data,
        titleKeysField: {
          'title': item.title,
          'upper': item.title.toUpperCase(),
          'initials': titleInitials(item.title),
          'full': full,
          'letter': titleLetter(item.title),
        },
      }),
    );
  }
  if (sort) {
    values.sort((a, b) {
      final left = object(a.data[titleKeysField]),
          right = object(b.data[titleKeysField]);
      for (final key in ['letter', 'initials', 'title']) {
        final result = (left[key] as String).compareTo(right[key] as String);
        if (result != 0) return result;
      }
      return a.id.compareTo(b.id);
    });
  }
  return values;
}

class CatalogView {
  CatalogView(this.items, this.offsets);
  final List<MediaItem> items;
  final Map<String, int> offsets;
}

/// No conversion or sort while searching or dragging the letter rail.
CatalogView selectCatalog((List<MediaItem>, String, bool?) input) {
  final (source, search, played) = input;
  final match = SearchMatch(search);
  final items = <MediaItem>[], offsets = <String, int>{};
  for (final item in source) {
    if (played != null &&
        (object(item.data['UserData'])['Played'] == true) != played) {
      continue;
    }
    final keys = object(item.data[titleKeysField]);
    if (match.needle.isNotEmpty &&
        !match.accepts(item.title) &&
        !['initials', 'full'].any(
          (key) =>
              searchText(keys[key]?.toString() ?? '').contains(match.needle),
        )) {
      continue;
    }
    final letter = keys['letter']?.toString();
    if (letter != null) offsets.putIfAbsent(letter, () => items.length);
    items.add(item);
  }
  return CatalogView(items, offsets);
}
