import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'models.dart';
import 'log.dart';

/// Server-confirmed removals, independent of user visibility preferences and
/// watch progress. Persist before stale snapshots can be shown on the next run.
class LibraryRemovals extends ChangeNotifier {
  LibraryRemovals(this.prefs);
  final SharedPreferences prefs;
  final _keys = Expando<String>();
  final _records = <String, Set<String>>{};
  final _progressHolds = <String, Set<String>>{};
  final _progressRevisions = <String, Map<String, int>>{};
  final _reportedHolds = <String>{};
  final _corruptHolds = <String>{};
  Future<void> _holdWrite = Future.value();
  Future<void> _write = Future.value();
  String? warning;
  String key(Session account) => _keys[account] ??=
      'yingyu.library.removed.v1.${sha256.convert(utf8.encode(accountKey(account)))}';
  Set<String> ids(Session account) => _records.putIfAbsent(key(account), () {
    try {
      return (prefs.getStringList(key(account)) ?? const <String>[]).toSet();
    } catch (_) {
      warning = '资源删除记录读取失败，请刷新核对';
      return <String>{};
    }
  });
  bool allows(Session account, MediaItem item) =>
      !references(item, ids(account));

  // A missing detail response pauses only automatic progress work. It does not
  // delete the checkpoint or claim that the whole library item was removed.
  String _holdKey(Session account) => '${key(account)}.progress-paused.v1';
  Set<String> _holds(Session account) =>
      _progressHolds.putIfAbsent(key(account), () {
        try {
          return (prefs.getStringList(_holdKey(account)) ?? const <String>[])
              .toSet();
        } catch (_) {
          _corruptHolds.add(key(account));
          return <String>{};
        }
      });
  String progressReference(Session account, String id) => sha256
      .convert(utf8.encode('${key(account)}:$id'))
      .toString()
      .substring(0, 12);
  int progressRevision(Session account, String id) =>
      _progressRevisions.putIfAbsent(key(account), () => {})[id] ??= 0;
  bool needsConfirmation(Session account, String id) =>
      ids(account).contains(id) ||
      _holds(account).contains(id) ||
      (_progressRevisions[key(account)]?.containsKey(id) ?? false);
  bool hasConfirmations(Session account) =>
      ids(account).isNotEmpty ||
      _holds(account).isNotEmpty ||
      (_progressRevisions[key(account)]?.isNotEmpty ?? false);

  bool progressAllowed(
    Session account,
    String id,
    DiagnosticLog log, {
    MediaItem? item,
  }) {
    final removed =
        ids(account).contains(id) || item != null && !allows(account, item);
    final held = _holds(account).contains(id);
    final corrupt = _corruptHolds.contains(key(account));
    if (!removed && !held && !corrupt) return true;
    if (_reportedHolds.add('${key(account)}:$id')) {
      log.add(
        LogArea.progress,
        '自动补传暂停：资源摘要=${progressReference(account, id)}；'
        '原因=${corrupt
            ? '本机补传暂停状态无法读取'
            : removed
            ? '目录或通知确认资源已删除'
            : '资源读取曾返回 HTTP 404/410'}；'
        '本机观看记录保留，正常同步确认资源恢复后再补传',
        level: LogLevel.warning,
      );
    }
    return false;
  }

  Future<void> pauseProgress(
    Session account,
    String id,
    int revision,
    DiagnosticLog log,
    int status,
  ) async {
    if (progressRevision(account, id) != revision) return;
    if (!_holds(account).add(id)) return;
    _reportedHolds.add('${key(account)}:$id');
    log.add(
      LogArea.progress,
      '自动补传暂停：资源摘要=${progressReference(account, id)}；'
      '原因=详情返回 HTTP $status；本机观看记录保留，不再定时探测；'
      '正常同步确认资源恢复后再补传',
      level: LogLevel.warning,
    );
    try {
      await _saveHolds(account);
    } catch (e) {
      log.add(LogArea.progress, safeError(e), level: LogLevel.error);
    }
  }

  Future<void> _saveHolds(Session account) {
    final snapshot = _holds(account).toList();
    final result = _holdWrite.then((_) async {
      if (!await prefs.setStringList(_holdKey(account), snapshot)) {
        throw const AppFailure('补传暂停状态保存失败，本次运行已暂停，观看记录保留');
      }
    });
    _holdWrite = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static bool references(MediaItem item, Set<String> removed) =>
      removed.isNotEmpty &&
      [
        item.id,
        item.data['SeriesId'],
        item.data['SeasonId'],
        item.data['ParentId'],
        ...?(item.data['_YingyuLibraryIdsV1'] as List?),
      ].any((id) => id is String && removed.contains(id));

  Future<void> apply(
    Session account, {
    Set<String> removed = const {},
    Set<String> added = const {},
    DiagnosticLog? log,
  }) {
    final tracked = _progressRevisions[key(account)];
    if (tracked != null) {
      for (final id in tracked.keys) {
        if (removed.contains(id) || added.contains(id)) {
          tracked[id] = tracked[id]! + 1;
        }
      }
    }
    final holds = _holds(account);
    final restored = holds.intersection(added.difference(removed));
    holds.removeAll(restored);
    for (final id in added) {
      _reportedHolds.remove('${key(account)}:$id');
    }
    final holdSave = restored.isEmpty
        ? Future<void>.value()
        : _saveHolds(account);
    if (restored.isNotEmpty) {
      log?.add(
        LogArea.progress,
        '正常同步确认资源恢复：${restored.length} 项重新允许自动补传；仍沿用观看进度冲突核对',
      );
    }
    final values = ids(account);
    final previous = Set<String>.of(values);
    values.removeAll(added);
    values.addAll(removed);
    values.remove('');
    if (setEquals(previous, values) && warning == null) return holdSave;
    notifyListeners();
    final snapshot = values.toList();
    final write = _write = _write.then((_) async {
      try {
        if (!await prefs.setStringList(key(account), snapshot)) {
          throw const AppFailure('资源删除记录保存失败，请重试刷新');
        }
        warning = null;
      } catch (_) {
        warning = '资源删除记录保存失败，请重试刷新';
      }
    });
    return Future.wait([holdSave, write]).then((_) {});
  }
}
