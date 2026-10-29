import 'package:pinyin/pinyin.dart';
import 'models.dart';
import 'broad_search.dart';

final _initials = <String, String>{};
String titleInitials(String title) {
  final saved = _initials[title];
  if (saved != null) return saved;
  String result;
  try {
    result = PinyinHelper.getShortPinyin(title).trim().toUpperCase();
  } catch (_) {
    result = title.trim().toUpperCase();
  }
  _initials[title] = result;
  if (_initials.length > 20000) _initials.remove(_initials.keys.first);
  return result;
}

String titleLetter(String title) {
  final text = titleInitials(title);
  return text.isNotEmpty && RegExp(r'^[A-Z]').hasMatch(text) ? text[0] : '#';
}

List<MediaItem> alphabetize(Iterable<MediaItem> items) {
  final ids = <String>{};
  return items.where((item) => ids.add(item.id.toLowerCase())).toList()
    ..sort((a, b) {
      final bucket = titleLetter(a.title).compareTo(titleLetter(b.title));
      if (bucket != 0) return bucket;
      final initials = titleInitials(a.title).compareTo(titleInitials(b.title));
      return initials != 0 ? initials : a.title.compareTo(b.title);
    });
}

bool matchesTitle(MediaItem item, String search) {
  final match = SearchMatch(search);
  if (match.needle.isEmpty ||
      match.accepts(item.title) ||
      searchText(titleInitials(item.title)).contains(match.needle)) {
    return true;
  }
  return searchText(
    PinyinHelper.getPinyinE(
      item.title,
      separator: '',
      format: PinyinFormat.WITHOUT_TONE,
    ),
  ).contains(match.needle);
}
