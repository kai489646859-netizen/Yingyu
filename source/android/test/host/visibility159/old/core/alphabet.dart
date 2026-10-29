import 'package:pinyin/pinyin.dart';
import 'models.dart';

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
  final needle = search.trim().toUpperCase();
  if (needle.isEmpty) return true;
  if (item.title.toUpperCase().contains(needle) ||
      titleInitials(item.title).contains(needle)) {
    return true;
  }
  return PinyinHelper.getPinyinE(
    item.title,
    separator: '',
    format: PinyinFormat.WITHOUT_TONE,
  ).toUpperCase().contains(needle);
}
