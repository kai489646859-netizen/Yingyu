import 'dart:async';
import 'package:flutter/foundation.dart';
import 'accounts.dart';
import 'emby.dart';
import 'models.dart';
import 'broad_search.dart';

class SearchSource {
  SearchSource(this.account, this.api);
  final SavedAccount account;
  final EmbyClient api;
  final items = <MediaItem>[];
  final matches = BroadSearch(parallel: 1);
  bool busy = false, more = false;
  int offset = 0;
  String? error;
}

/// Requests retain their own credentials. Results never merge by naked item ID.
class FederatedSearch extends ChangeNotifier {
  FederatedSearch(EmbyClient transport, List<SavedAccount> accounts)
    : sources = [
        for (final account in accounts)
          SearchSource(account, transport.forAccount(account.session)),
      ];
  final List<SearchSource> sources;
  String query = '';
  int _generation = 0;
  bool _closed = false;
  final _pauseOwner = Object();
  bool get busy => sources.any((s) => s.busy);
  void cancel() {
    _generation++;
    for (final source in sources) {
      source.api.backgroundWork.pause(_pauseOwner, true);
      if (source.busy && query.isNotEmpty) {
        source.error = '搜索已暂停，点击重试';
      }
      source.busy = false;
    }
  }

  Future<void> search(String term) async {
    cancel();
    query = term.trim();
    final generation = _generation;
    for (final source in sources) {
      source.items.clear();
      source.matches.reset();
      source.offset = 0;
      source.more = false;
      source.error = source.account.needsLogin ? '需要重新登录' : null;
      source.busy = query.isNotEmpty && !source.account.needsLogin;
      source.api.backgroundWork.pause(_pauseOwner, false);
    }
    notifyListeners();
    if (query.isEmpty) return;
    var cursor = 0;
    Future<void> worker() async {
      while (!_closed && generation == _generation && cursor < sources.length) {
        final source = sources[cursor++];
        if (source.account.needsLogin) continue;
        await _load(source, generation);
      }
    }

    await Future.wait(
      List.generate(sources.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<void> more(SearchSource source) async {
    if (_closed || source.busy || !source.more || query.isEmpty) return;
    source.api.backgroundWork.pause(_pauseOwner, false);
    source.busy = true;
    notifyListeners();
    await _load(source, _generation);
  }

  Future<void> retry(SearchSource source) async {
    if (_closed || source.busy || source.account.needsLogin || query.isEmpty) {
      return;
    }
    source.api.backgroundWork.pause(_pauseOwner, false);
    source.busy = true;
    source.error = null;
    notifyListeners();
    await _load(source, _generation);
  }

  Future<void> _load(SearchSource source, int generation) async {
    final term = query;
    try {
      final start = source.offset;
      final before = List<MediaItem>.of(source.items);
      void accept(ItemPage page) {
        if (_closed || generation != _generation) return;
        final ids = <String>{};
        source.items
          ..clear()
          ..addAll([...before, ...page.items].where((i) => ids.add(i.id)));
        source.offset = source.items.length;
        source.more = source.offset < page.total;
        source.error = null;
        notifyListeners();
      }

      final page = await source.api.backgroundWork.run(
        () => source.matches.search(
          term,
          start: start,
          early: false,
          continueSearch: true,
          allowed: () =>
              !_closed &&
              generation == _generation &&
              !source.api.backgroundWork.paused,
          fetch: (part, offset, _) =>
              source.api.items(search: part, start: offset),
          onPartial: accept,
        ),
      );
      if (_closed || generation != _generation) return;
      accept(page);
      source.error = null;
    } catch (error) {
      if (_closed || generation != _generation) return;
      source.error = safeError(error);
    } finally {
      if (!_closed && generation == _generation) {
        source.busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _closed = true;
    cancel();
    for (final source in sources) {
      source.api.close();
    }
    super.dispose();
  }
}
