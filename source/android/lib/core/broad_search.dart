import 'dart:async';
import 'models.dart';

/// Matching is literal, not phonetic guessing. Ignore separators and width.
String searchText(String text) => String.fromCharCodes(
  text.runes.map((r) => r >= 0xff01 && r <= 0xff5e ? r - 0xfee0 : r),
).toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

class SearchMatch {
  SearchMatch(String query)
    : needle = searchText(query),
      letters = searchText(query).runes.toSet();
  final String needle;
  final Set<int> letters;
  bool accepts(String value) =>
      needle.isEmpty || searchText(value).runes.any(letters.contains);
  int score(String value) {
    final text = searchText(value);
    if (needle.isEmpty) return 0;
    if (text == needle) return 0;
    if (text.contains(needle)) return 100;
    final found = text.runes.toSet().intersection(letters).length;
    if (found == 0) return 1000000;
    var at = 0;
    final runes = needle.runes.toList();
    for (final r in text.runes) {
      if (at < runes.length && r == runes[at]) at++;
    }
    if (at == runes.length) return 200;
    return 300 + letters.length - found;
  }
}

class _Branch {
  _Branch(this.term, this.prefix);
  final String term;
  final bool prefix;
  int offset = 0;
  bool more = true;
}

/// Only server-filtered queries, never a full-directory scan. Each user action
/// admits at most six requests; all other branches/pages require Load More.
class BroadSearch {
  BroadSearch({this.persons = false, this.parallel = 2});
  final bool persons;
  final int parallel;
  int _epoch = 0;
  String? _query;
  late SearchMatch _match;
  final _items = <String, MediaItem>{};
  final _sealed = <String>[];
  List<_Branch> _branches = [];
  int _cursor = 0;
  Future<void>? _pending;
  bool get hasMore => _branches.any((b) => b.more) || _pending != null;
  void reset() {
    _epoch++;
    _query = null;
    _items.clear();
    _sealed.clear();
    _branches = [];
    _cursor = 0;
    _pending = null;
  }

  List<MediaItem> get ordered {
    final seen = _sealed.toSet();
    final tail = _items.values.where((p) => !seen.contains(p.id)).toList();
    final insertion = {for (var i = 0; i < tail.length; i++) tail[i].id: i};
    final ranks = {for (final p in tail) p.id: _match.score(p.title)};
    tail.sort((a, b) {
      final rank = ranks[a.id]!.compareTo(ranks[b.id]!);
      return rank != 0 ? rank : insertion[a.id]!.compareTo(insertion[b.id]!);
    });
    return [for (final id in _sealed) _items[id]!, ...tail];
  }

  ItemPage page(int start) => ItemPage(
    ordered.skip(start).take(48).toList(),
    _items.length + (hasMore ? 1 : 0),
  );

  Future<ItemPage> search(
    String query, {
    required Future<ItemPage> Function(String, int, bool) fetch,
    required bool Function() allowed,
    void Function(ItemPage)? onPartial,
    int start = 0,
    bool early = true,
    bool continueSearch = false,
  }) async {
    query = query.trim();
    final match = SearchMatch(query);
    if (match.needle.isEmpty || start < 0 || !allowed()) return ItemPage([], 0);
    if (_query != query || start == 0 && !continueSearch) {
      reset();
      _query = query;
      _match = match;
      final terms = <String>{
        query,
        match.needle,
        for (final r in match.needle.runes) String.fromCharCode(r),
      };
      _branches = [
        for (final term in terms) ...[
          _Branch(term, false),
          if (persons) _Branch(term, true),
        ],
      ];
    }
    final epoch = _epoch;
    bool active() => epoch == _epoch && allowed();
    if (_pending != null) {
      await _pending;
      if (!active()) return ItemPage([], 0);
    }
    // Once pagination starts, delivered IDs cannot migrate across page edges.
    if (start > 0) {
      final ids = ordered.take(start).map((p) => p.id).toList();
      _sealed
        ..clear()
        ..addAll(ids);
    }
    if (start > 0 && _items.length > start || !hasMore) return page(start);
    final batch = <_Branch>[];
    var visited = 0;
    while (visited < _branches.length && batch.length < 6) {
      final b = _branches[_cursor++ % _branches.length];
      visited++;
      if (b.more) batch.add(b);
    }
    final ready = Completer<ItemPage>();
    var cursor = 0, failures = 0;
    Object? error;
    Future<void> worker() async {
      while (active() && cursor < batch.length) {
        final b = batch[cursor++];
        try {
          final response = await fetch(b.term, b.offset, b.prefix);
          if (!active()) return;
          b.offset += response.items.length;
          b.more =
              response.items.isNotEmpty &&
              (response.countKnown
                  ? b.offset < response.total
                  : response.items.length >= 48);
          for (final item in response.items) {
            if (item.id.isEmpty ||
                persons &&
                    ((item.type != 'Person' && item.type.isNotEmpty) ||
                        !_match.accepts(item.title))) {
              continue;
            }
            _items[item.id] = item;
          }
          final result = page(start);
          onPartial?.call(result);
          if (early && result.items.isNotEmpty && !ready.isCompleted) {
            ready.complete(result);
          }
        } catch (failure) {
          failures++;
          error = failure;
          if (active()) b.more = false;
        }
      }
    }

    late final Future<void> work;
    work = Future.wait(List.generate(parallel, (_) => worker())).then((_) {
      if (identical(_pending, work)) _pending = null;
      if (!active()) {
        if (!ready.isCompleted) ready.complete(ItemPage([], 0));
        return;
      }
      final result = page(start);
      onPartial?.call(result);
      if (!ready.isCompleted) {
        if (batch.isNotEmpty &&
            failures == batch.length &&
            result.items.isEmpty) {
          ready.completeError(error!);
        } else {
          ready.complete(result);
        }
      }
    });
    _pending = work;
    unawaited(work);
    await ready.future;
    return active() ? page(start) : ItemPage([], 0);
  }
}
