import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'models.dart';
import 'version_groups.dart';
import 'library_removals.dart';

class HomeOrder extends ChangeNotifier {
  HomeOrder(this.prefs) {
    removals.addListener(notifyListeners);
  }
  final SharedPreferences prefs;
  late final removals = LibraryRemovals(prefs);
  @override
  void dispose() {
    removals.removeListener(notifyListeners);
    removals.dispose();
    super.dispose();
  }

  String key(Session account) =>
      'yingyu.home.order.v1.${sha256.convert(utf8.encode(accountKey(account)))}';
  List<String> read(Session account) =>
      prefs.getStringList(key(account)) ?? const [];
  final _visibilityKeys = Expando<String>();
  String visibilityKey(Session account) => _visibilityKeys[account] ??=
      'yingyu.home.hidden.v1.${sha256.convert(utf8.encode(accountKey(account)))}';
  final _visibility = <String, Set<String>>{};
  final _corrupt = <String>{};
  final _members = <String, Map<String, Set<String>>>{};
  final _libraries = <String, Set<String>>{};
  final _ready = <String>{};
  final _previewRevisions = <String, int>{};
  final _errors = <String, String>{};
  final _serverScopes = <String, Set<String>>{};
  final _serverSessions = <String, Session>{};
  final _serverItems = <String, Set<String>>{};
  final _serverRevisions = <String, int>{};
  int serverRevision(Session account) =>
      _serverRevisions[visibilityKey(account)] ?? 0;
  bool serverScopeKnown(Session account) =>
      identical(_serverSessions[visibilityKey(account)], account) &&
      _serverScopes.containsKey(visibilityKey(account));
  bool serverHandlesHidden(Session account) {
    final owner = visibilityKey(account), scopes = _serverScopes[owner];
    return !_corrupt.contains(owner) &&
        _hidden(account).isNotEmpty &&
        serverScopeKnown(account) &&
        scopes != null &&
        !_hidden(account).any(scopes.contains);
  }

  /// Only a successful live user Views response establishes this shortcut.
  /// A cached list or a failed request cannot prove permission was revoked.
  void observeServerLibraries(Session account, Iterable<String> ids) {
    final owner = visibilityKey(account), scopes = ids.toSet();
    if (serverScopeKnown(account) && setEquals(_serverScopes[owner], scopes)) {
      return;
    }
    _serverSessions[owner] = account;
    _serverScopes[owner] = scopes;
    _serverRevisions[owner] = serverRevision(account) + 1;
    _serverItems.remove(owner);
    _members.remove(owner);
    _ready.remove(owner);
    _errors.remove(owner);
    notifyListeners();
  }

  /// Fresh user-scoped metadata confirms only the exact returned identities.
  /// Nothing is persisted as permission evidence across process restarts.
  void observeServerItems(
    Session account,
    Iterable<MediaItem> items, {
    required int revision,
  }) {
    if (!serverScopeKnown(account) || revision != serverRevision(account)) {
      return;
    }
    final known = _serverItems.putIfAbsent(visibilityKey(account), () => {});
    final before = known.length;
    known.addAll(items.map((item) => item.id).where((id) => id.isNotEmpty));
    if (known.length != before && serverHandlesHidden(account)) {
      notifyListeners();
    }
  }

  bool needsServerConfirmation(Session account, Iterable<MediaItem> items) =>
      serverHandlesHidden(account) &&
      items.any((item) => !_serverConfirmed(account, item));

  bool _serverConfirmed(Session account, MediaItem item) {
    if (item is VersionGroup) {
      return item.versions.every((value) => _serverConfirmed(account, value));
    }
    return _serverItems[visibilityKey(account)]?.contains(item.id) == true;
  }

  // Callers editing a selection keep a mutable copy; per-item checks reuse
  // the committed set without copying or hashing the account again.
  Set<String> hidden(Session account) => Set.of(_hidden(account));
  Set<String> _hidden(Session account) =>
      _visibility.putIfAbsent(visibilityKey(account), () {
        try {
          return Set.unmodifiable(
            prefs.getStringList(visibilityKey(account)) ?? const <String>[],
          );
        } catch (_) {
          _corrupt.add(visibilityKey(account));
          return <String>{};
        }
      });

  bool filtering(Session account) =>
      _hidden(account).isNotEmpty || _corrupt.contains(visibilityKey(account));
  bool ready(Session account) =>
      !filtering(account) ||
      serverHandlesHidden(account) ||
      (!_corrupt.contains(visibilityKey(account)) &&
          _ready.contains(visibilityKey(account)));
  String? visibilityError(Session account) =>
      _corrupt.contains(visibilityKey(account))
      ? '分区设置无法读取，请在分区排序中重新设置'
      : _errors[visibilityKey(account)];
  void beginResolution(Session account) {
    final owner = visibilityKey(account);
    _errors.remove(owner);
    notifyListeners();
  }

  void failResolution(Session account, String message) {
    _errors[visibilityKey(account)] = message;
    notifyListeners();
  }

  void observeLibraries(Session account, Iterable<String> ids) {
    _libraries[visibilityKey(account)] = ids.toSet();
  }

  // A scoped latest response already identifies these items. Retain known
  // memberships while refreshing; unknown items still fail closed.
  void observeSection(Session account, String library, List<MediaItem> items) {
    final members = _members.putIfAbsent(visibilityKey(account), () => {});
    for (final item in items) {
      members.putIfAbsent(item.id, () => {}).add(library);
    }
  }

  int previewHidden(Session account, Set<String> ids) {
    final owner = visibilityKey(account);
    final revision = (_previewRevisions[owner] ?? 0) + 1;
    _previewRevisions[owner] = revision;
    _visibility[owner] = Set.unmodifiable(ids);
    notifyListeners();
    return revision;
  }

  void resolveMembership(
    Session account,
    List<MediaItem> items,
    List<String> scopes, {
    bool notify = true,
  }) {
    final owner = visibilityKey(account);
    _members[owner] = {
      for (final item in items)
        item.id: (item.data['_YingyuLibraryIdsV1'] as List? ?? const [])
            .whereType<String>()
            .toSet(),
    };
    _libraries[owner] = scopes.toSet();
    _ready.add(owner);
    _errors.remove(owner);
    if (notify) notifyListeners();
  }

  bool allows(Session account, MediaItem item) {
    if (item is VersionGroup) {
      return item.versions.any((v) => allows(account, v));
    }
    if (!removals.allows(account, item)) return false;
    final excluded = _hidden(account), owner = visibilityKey(account);
    if (_corrupt.contains(owner)) return false;
    if (excluded.isEmpty) return true;
    if (excluded.contains(item.id)) return false;
    if (serverHandlesHidden(account)) {
      // Old DTO folder tags cannot grant visibility. Current server replies
      // replace the full-catalogue scan only while every locally hidden view
      // is absent from the authenticated user's live view list.
      return _serverScopes[owner]!.contains(item.id) ||
          _serverConfirmed(account, item);
    }
    if (_libraries[owner]?.contains(item.id) == true &&
        const [
          '',
          'CollectionFolder',
          'Folder',
          'UserView',
        ].contains(item.type)) {
      return true;
    }
    final memberships = <String>{
      for (final id in [
        item.id,
        item.data['SeriesId'],
        item.data['SeasonId'],
        item.data['ParentId'],
      ])
        ...?_members[owner]?[id?.toString()],
    };
    // Missing folder identity is withheld until a complete catalogue resolves
    // it. A stale DTO, title or TMDB match can never grant access.
    return memberships.isNotEmpty && !memberships.any(excluded.contains);
  }

  Future<void> saveHidden(
    Session account,
    Set<String> ids, {
    int? previewRevision,
  }) async {
    if (ids.any((id) => id.isEmpty)) {
      throw const AppFailure('分区资料已更新，请重新打开');
    }
    final before = _hidden(account);
    if (!await prefs.setStringList(visibilityKey(account), ids.toList())) {
      throw const AppFailure('应用内显示设置保存失败');
    }
    // A newer switch preview can already exist while this write is pending.
    if (identical(_hidden(account), before) &&
        (previewRevision == null ||
            previewRevision == _previewRevisions[visibilityKey(account)])) {
      _visibility[visibilityKey(account)] = Set.unmodifiable(ids);
    }
    _corrupt.remove(visibilityKey(account));
    notifyListeners();
  }

  /// Shared by every discovery surface and the final navigation/play guards.
  List<MediaItem> visible(Session account, List<MediaItem> items) {
    if (!filtering(account) && removals.ids(account).isEmpty) return items;
    bool allowed(MediaItem item) => allows(account, item);
    return [
      for (final item in items)
        if (item is VersionGroup)
          ..._visibleVersions(item, allowed)
        else if (allowed(item))
          item,
    ];
  }

  List<MediaItem> _visibleVersions(
    VersionGroup group,
    bool Function(MediaItem) allowed,
  ) {
    final members = group.versions.where(allowed).toList();
    return members.isEmpty
        ? []
        : [
            members.length == 1
                ? members.single
                : VersionGroup(group.owner, members),
          ];
  }

  List<T> apply<T>(Session account, List<T> sections, String Function(T) id) {
    final remaining = {for (final section in sections) id(section): section};
    final result = <T>[];
    for (final saved in read(account)) {
      final item = remaining.remove(saved);
      if (item != null) result.add(item);
    }
    return [...result, ...remaining.values];
  }

  Future<void> save(Session account, List<String> ids) async {
    if (ids.any((id) => id.isEmpty) || ids.toSet().length != ids.length) {
      throw const AppFailure('首页分区已更新，请重新打开排序');
    }
    if (!await prefs.setStringList(key(account), ids)) {
      throw const AppFailure('首页顺序保存失败');
    }
    notifyListeners();
  }
}
