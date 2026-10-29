import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'emby.dart';
import 'log.dart';
import 'models.dart';
import 'progress.dart';
import 'library_removals.dart';

/// One durable receipt per real media ID. No media addresses or credentials.
/// A receipt is created only by confirmed natural EOF, never by opening details.
class CompletionSync extends ChangeNotifier {
  CompletionSync(this.prefs, this.log, {LibraryRemovals? removals})
    : removals = removals ?? LibraryRemovals(prefs);
  final LibraryRemovals removals;
  final SharedPreferences prefs;
  final DiagnosticLog log;
  final Map<String, Future<void>> _running = {};
  final Map<String, String?> _runningReceipt = {};
  final Map<String, Future<void>> _retrying = {};
  final Map<String, String> _retryAfter = {};
  String prefix(Session account) =>
      'yingyu.completed.v1.${sha256.convert(utf8.encode(accountKey(account)))}.';
  String key(Session account, String id) =>
      '${prefix(account)}${Uri.encodeComponent(id)}';
  Json? receipt(Session account, String id) {
    final raw = prefs.getString(key(account, id));
    if (raw == null) return null;
    try {
      final data = object(jsonDecode(raw));
      if (data['id'] != id || DateTime.tryParse('${data['at']}') == null) {
        throw const FormatException();
      }
      return data;
    } catch (_) {
      throw const AppFailure('本机已看记录无法读取，原记录已保留');
    }
  }

  bool pending(Session account, String id) =>
      receipt(account, id)?['confirmed'] == false;
  bool superseded(Session account, String id) =>
      receipt(account, id)?['superseded'] == true;
  final Map<String, String> _unpersistedSupersede = {};

  /// A real EOF remains a historical fact. A subsequent viewing checkpoint
  /// must not let that old receipt reset its new server position to zero.
  Future<void> supersede(
    Session account,
    String id, {
    bool Function()? allowed,
  }) async {
    if (allowed?.call() == false) return;
    final name = key(account, id);
    final value = receipt(account, id);
    final running = _running[name];
    String? warning;
    if (value != null &&
        (value['confirmed'] == false ||
            _unpersistedSupersede[name] == value['at']) &&
        (value['superseded'] != true ||
            _unpersistedSupersede[name] == value['at'])) {
      // setString updates the in-memory value before its platform await. Do
      // not write an old receipt over a later EOF, including the same zero.
      if (receipt(account, id)?['at'] == value['at']) {
        try {
          if (!await prefs.setString(
            name,
            jsonEncode({...value, 'superseded': true}),
          )) {
            throw const AppFailure('新观看进度保护标记保存失败');
          }
          _unpersistedSupersede.remove(name);
          notifyListeners();
        } catch (error) {
          _unpersistedSupersede[name] = value['at'] as String;
          warning = '新观看进度保护标记保存失败：${safeError(error)}；旧已看记录仍需核对';
        }
      }
    }
    // markCompleted may already have left this process. Let that bounded job
    // settle before the new checkpoint and its API report can overtake it.
    if (allowed?.call() != false) {
      try {
        await running;
      } catch (_) {
        // The original sync caller retains this failure. A superseded old job
        // must not prevent saving the new viewing checkpoint.
      }
    }
    if (warning != null) throw AppFailure(warning);
    if (allowed?.call() == false) return;
  }

  bool completed(Session account, MediaItem item) {
    if (object(item.data['UserData'])['Played'] == true) return true;
    final value = receipt(account, item.id);
    return value != null &&
        (value['confirmed'] == false ||
            value['baseline'] == progressFingerprint(item));
  }

  MediaItem? latest(Session account, String seriesId) {
    Json? last;
    for (final name in prefs.getKeys().where(
      (k) => k.startsWith(prefix(account)),
    )) {
      final id = Uri.decodeComponent(name.substring(prefix(account).length));
      final value = receipt(account, id);
      if (value == null || object(value['item'])['SeriesId'] != seriesId) {
        continue;
      }
      if (last == null || '${value['at']}'.compareTo('${last['at']}') > 0) {
        last = value;
      }
    }
    if (last == null) return null;
    return MediaItem({
      ...object(last['item']),
      'UserData': {
        'Played': true,
        'PlaybackPositionTicks': 0,
        'LastPlayedDate': last['at'],
      },
    });
  }

  Future<void> remember(
    Session account,
    MediaItem item,
    Duration duration,
  ) async {
    if (item.id.isEmpty) throw const AppFailure('缺少影片编号，无法保存已看记录');
    final data = {
      'id': item.id,
      'at': DateTime.now().toUtc().toIso8601String(),
      'confirmed': false,
      'baseline': progressFingerprint(item),
      'item': {
        for (final field in [
          'Id',
          'Type',
          'Name',
          'SeriesId',
          'SeasonId',
          'IndexNumber',
          'ParentIndexNumber',
          'SeriesName',
        ])
          if (item.data.containsKey(field)) field: item.data[field],
        'RunTimeTicks': ticks(duration),
      },
    };
    if (!await prefs.setString(key(account, item.id), jsonEncode(data))) {
      throw const AppFailure('本机已看记录保存失败');
    }
    _unpersistedSupersede.remove(key(account, item.id));
    notifyListeners();
  }

  Future<void> forgetConfirmed(Session account, String id) async {
    final name = key(account, id);
    await _running[name];
    final value = receipt(account, id);
    if (value == null) return;
    if (value['confirmed'] != true) {
      throw const AppFailure('此片有待同步的已看记录，请同步后再修改');
    }
    if (!await prefs.remove(name)) {
      throw const AppFailure('Emby 已更新，但本机已看记录清理失败，请重试');
    }
    notifyListeners();
  }

  Future<void> syncOne(
    EmbyClient api,
    Session account,
    String id, {
    bool Function()? allowed,
  }) {
    final name = key(account, id);
    final requestedAt = receipt(account, id)?['at'] as String?;
    final active = _running[name];
    if (active != null) {
      if (_runningReceipt[name] == requestedAt) return active;
      // A later real EOF owns a different receipt. Joining the old job alone
      // must not silently skip synchronization of this new completion.
      return () async {
        try {
          await active;
        } catch (_) {
          // Its original caller keeps the earlier receipt's failure.
        }
        if (api.session != account || allowed?.call() == false) return;
        if (receipt(account, id)?['at'] != requestedAt) return;
        await syncOne(api, account, id, allowed: allowed);
      }();
    }
    _runningReceipt[name] = requestedAt;
    return _running[name] ??= _syncOne(api, account, id, allowed).whenComplete(
      () {
        _running.remove(name);
        _runningReceipt.remove(name);
      },
    );
  }

  Future<void> _syncOne(
    EmbyClient api,
    Session account,
    String id,
    bool Function()? allowed,
  ) async {
    final value = receipt(account, id);
    if (value == null || value['confirmed'] == true) return;
    final item = MediaItem(object(value['item']));
    bool eligible() => removals.progressAllowed(account, id, log, item: item);
    if (!eligible()) return;
    Json? current() {
      if (api.session != account) throw const AppFailure('账号已切换，已看记录保留待同步');
      if (allowed?.call() == false) throw const AppFailure('稍后继续补传已看记录');
      final latest = receipt(account, id);
      return latest?['at'] == value['at'] ? latest : null;
    }

    if (current() == null) return;
    Future<MediaItem?> read() async {
      final revision = removals.progressRevision(account, id);
      try {
        final saved = await api.detail(
          id,
          requestTimeout: const Duration(seconds: 3),
        );
        if (current() == null) return null;
        if (!eligible()) return null;
        if (saved.id != id) throw const AppFailure('已看核对资源编号不一致，记录保留');
        return saved;
      } on AppFailure catch (e) {
        if (api.session == account &&
            allowed?.call() != false &&
            (e.status == 404 || e.status == 410)) {
          await removals.pauseProgress(account, id, revision, log, e.status!);
          return null;
        }
        rethrow;
      }
    }

    var saved = await read();
    if (saved == null) return;
    var latest = current();
    if (latest == null) return;
    if (object(saved.data['UserData'])['Played'] != true) {
      if (latest['superseded'] == true) {
        throw const AppFailure('此已看记录后已有新的观看进度，保留待核对');
      }
      // Do not erase a newer rewatch on another device by marking an old
      // completion. Keep this receipt so the conflict remains visible.
      final newer = DateTime.tryParse(
        '${object(saved.data['UserData'])['LastPlayedDate']}',
      );
      final at = DateTime.parse(value['at'] as String);
      if (saved.resume > Duration.zero && newer != null && newer.isAfter(at)) {
        throw const AppFailure('Emby 有较新的观看进度，旧已看记录保留待核对');
      }
      latest = current();
      if (latest == null) return;
      if (latest['superseded'] == true) {
        throw const AppFailure('此已看记录后已有新的观看进度，保留待核对');
      }
      await api.markCompleted(id, at);
      if (current() == null) return;
      if (!eligible()) return;
      saved = await read();
      if (saved == null) return;
      if (current() == null) return;
    }
    if (object(saved.data['UserData'])['Played'] != true) {
      throw const AppFailure('Emby 尚未确认已看完，记录保留待同步');
    }
    // A delayed acknowledgement must not clear a later playback's receipt.
    latest = current();
    if (latest == null) return;
    if (!await prefs.setString(
      key(account, id),
      jsonEncode({...latest, 'confirmed': true}),
    )) {
      throw const AppFailure('已同步 Emby，但本机确认信息保存失败');
    }
    log.add(LogArea.progress, '本集已看完：Emby 已回读确认；本机记录保留');
    notifyListeners();
  }

  Future<void> retry(
    EmbyClient api,
    Session account, {
    bool Function()? allowed,
  }) {
    final name = prefix(account);
    return _retrying[name] ??= _retry(api, account, allowed).whenComplete(() {
      _retrying.remove(name);
    });
  }

  Future<void> _retry(
    EmbyClient api,
    Session account,
    bool Function()? allowed,
  ) async {
    final scope = prefix(account);
    final names = prefs.getKeys().where((k) => k.startsWith(scope)).toList()
      ..sort();
    final after = _retryAfter[scope];
    final ordered = after == null
        ? names
        : [
            ...names.where((n) => n.compareTo(after) > 0),
            ...names.where((n) => n.compareTo(after) <= 0),
          ];
    var tried = 0;
    for (final name in ordered) {
      if (api.session != account || allowed?.call() == false || tried >= 2) {
        return;
      }
      _retryAfter[scope] = name;
      try {
        final id = Uri.decodeComponent(name.substring(prefix(account).length));
        if (!pending(account, id)) continue;
        if (!removals.progressAllowed(
          account,
          id,
          log,
          item: MediaItem(object(receipt(account, id)?['item'])),
        )) {
          continue;
        }
        tried++;
        await syncOne(api, account, id, allowed: allowed);
      } catch (e) {
        log.add(
          LogArea.progress,
          '已看记录补传未完成：${safeError(e)}',
          level: LogLevel.warning,
        );
        // A disconnected server should not trigger a request for every episode.
        if (api.connection.hasProblem) return;
      }
    }
  }
}
