import 'models.dart';

/// Actor names only, scoped to one live client/account. No media or image reads.
/// SearchTerm can be word-based on a server; substring matching uses this small
/// paged person directory, rather than guessing wildcards in its search syntax.
class PersonNameIndex {
  final _people = <String, MediaItem>{};
  int _epoch = 0, _offset = 0;
  final _progressiveOrder = <String, List<String>>{};
  bool _complete = false;
  DateTime? _completedAt;
  Future<void>? _pending;
  String? _lastPage;
  static const pageSize = 256;

  void reset() {
    _epoch++;
    _people.clear();
    _progressiveOrder.clear();
    _offset = 0;
    _complete = false;
    _completedAt = null;
    _pending = null;
    _lastPage = null;
  }

  static String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), '');

  void _add(Iterable<MediaItem> values) {
    for (final person in values) {
      if (person.id.isNotEmpty &&
          person.data['Name'] is String &&
          person.title.trim().isNotEmpty &&
          (person.type == 'Person' || person.type.isEmpty)) {
        _people[person.id] = MediaItem({
          for (final field in [
            'Id',
            'Name',
            'Type',
            'PrimaryImageTag',
            'ImageTags',
            'ProviderIds',
            'Role',
          ])
            if (person.data.containsKey(field)) field: person.data[field],
        });
      }
    }
  }

  ItemPage _select(String query, int start, {bool progressive = false}) {
    final needle = _normalize(query);
    final matches =
        _people.values
            .where((p) => _normalize(p.title).contains(needle))
            .toList()
          ..sort((a, b) {
            final x = _normalize(a.title), y = _normalize(b.title);
            final prefix = (x.startsWith(needle) ? 0 : 1).compareTo(
              y.startsWith(needle) ? 0 : 1,
            );
            return prefix != 0
                ? prefix
                : x.compareTo(y) != 0
                ? x.compareTo(y)
                : a.id.compareTo(b.id);
          });
    if (progressive) {
      if (!_progressiveOrder.containsKey(needle) &&
          _progressiveOrder.length >= 16) {
        _progressiveOrder.remove(_progressiveOrder.keys.first);
      }
      final order = _progressiveOrder.putIfAbsent(needle, () => []);
      final known = order.toSet();
      order.addAll(matches.where((p) => known.add(p.id)).map((p) => p.id));
      final positions = {for (var i = 0; i < order.length; i++) order[i]: i};
      matches.sort((a, b) => positions[a.id]!.compareTo(positions[b.id]!));
    }
    return ItemPage(
      matches.skip(start).take(48).toList(),
      matches.length + (progressive && !_complete ? 1 : 0),
    );
  }

  Future<void> _advance(Future<ItemPage> Function(int) fetch, int epoch) async {
    if (_pending != null) return _pending!;
    final offset = _offset;
    final work = () async {
      final page = await fetch(offset);
      if (epoch != _epoch) return;
      final identity = page.items.map((p) => p.id).join('\u0000');
      if (page.items.isNotEmpty && identity == _lastPage) {
        throw const AppFailure('演员目录分页重复，已保留目前结果，请稍后重试');
      }
      if (page.items.isEmpty && page.countKnown && offset < page.total) {
        throw const AppFailure('演员目录尚未返回完整，已保留目前结果，请稍后重试');
      }
      _lastPage = identity;
      _add(page.items);
      _offset += page.items.length;
      _complete =
          page.items.isEmpty ||
          (page.countKnown
              ? _offset >= page.total
              : page.items.length < pageSize);
      if (_complete) _completedAt = DateTime.now();
    }();
    _pending = work;
    try {
      await work;
    } finally {
      if (identical(_pending, work)) _pending = null;
    }
  }

  Future<ItemPage> search(
    String term, {
    required Future<ItemPage> Function() direct,
    required Future<ItemPage> Function(int) fetch,
    required bool Function() allowed,
    int start = 0,
    void Function(ItemPage)? onPartial,
    bool progressive = false,
  }) async {
    if (term.trim().isEmpty || start < 0 || !allowed()) return ItemPage([], 0);
    if (_completedAt != null &&
        DateTime.now().difference(_completedAt!) > const Duration(minutes: 5)) {
      reset();
    }
    final epoch = _epoch;
    if (start == 0 || !_complete) {
      final result = await direct();
      if (epoch != _epoch || !allowed()) return ItemPage([], 0);
      _add(result.items);
    }
    if (allowed()) {
      onPartial?.call(_select(term, start, progressive: progressive));
    }
    if (progressive && _select(term, start).items.isNotEmpty) {
      return _select(term, start, progressive: true);
    }
    while (!_complete && allowed() && epoch == _epoch) {
      if (_offset >= 100000) throw const AppFailure('演员目录较大，已保留目前结果；请使用更完整的名字');
      await _advance(fetch, epoch);
      if (epoch != _epoch || !allowed()) break;
      onPartial?.call(_select(term, start, progressive: progressive));
      if (progressive && _select(term, start).items.isNotEmpty) break;
      if (!_complete) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    }
    return epoch == _epoch
        ? _select(term, start, progressive: progressive)
        : ItemPage([], 0);
  }
}
