import 'broad_search.dart';
import 'models.dart';

/// Current account's filtered Emby responses only, including character queries.
class PersonQuerySearch {
  final _search = BroadSearch(persons: true);
  void reset() => _search.reset();
  Future<ItemPage> search(
    String term, {
    required Future<ItemPage> Function(String, int, bool) fetch,
    required bool Function() allowed,
    void Function(ItemPage)? onPartial,
    int start = 0,
    bool append = false,
  }) => _search.search(
    term,
    fetch: fetch,
    allowed: allowed,
    onPartial: onPartial,
    start: start,
    continueSearch: append,
  );
}
