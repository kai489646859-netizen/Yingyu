import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'emby.dart';
import 'models.dart';

String accountKey(Session session) =>
    jsonEncode([session.base.toString(), session.userId]);

String accountName(Session session) =>
    session.username.trim().isEmpty ? '未命名账号' : session.username;

String accountServer(Session session) {
  final path = session.base.path.replaceFirst(RegExp(r'/emby/?$'), '');
  return '${session.base.authority}$path';
}

class SavedAccount {
  const SavedAccount(this.session, {this.needsLogin = false});
  final Session session;
  final bool needsLogin;
  String get id => accountKey(session);
  Map<String, dynamic> toJson() => {
    'session': session.toJson(),
    'needsLogin': needsLogin,
  };
}

/// One atomic document owns both the saved accounts and the selected account.
/// Passwords are never stored. Existing progress/cache keys are not rewritten.
class AccountStore {
  AccountStore(this.prefs);
  static const storageKey = 'yingyu.accounts.v1';
  final SharedPreferences prefs;
  List<SavedAccount> _accounts = [];
  String? _selected;
  bool _loaded = false;
  Future<void> _tail = Future.value();
  List<SavedAccount> get accounts => List.unmodifiable(_accounts);
  SavedAccount? get selected =>
      _accounts.where((a) => a.id == _selected).firstOrNull;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> load(Future<String> Function() deviceId) => _serial(() async {
    if (_loaded) return;
    final saved = prefs.getString(storageKey);
    if (saved != null) {
      try {
        final data = object(jsonDecode(saved));
        if (data['accounts'] is! List) throw const FormatException();
        final accounts = <SavedAccount>[];
        for (final row in objects(data['accounts'])) {
          final s = Session.fromJson(object(row['session']));
          if (s.userId.isEmpty ||
              s.token.isEmpty ||
              s.deviceId.isEmpty ||
              normalizeServer(s.base.toString()) != s.base) {
            throw const FormatException();
          }
          final a = SavedAccount(s, needsLogin: row['needsLogin'] == true);
          if (accounts.any((e) => e.id == a.id)) throw const FormatException();
          accounts.add(a);
        }
        final active = data['selected'] as String?;
        if (active != null && !accounts.any((a) => a.id == active)) {
          throw const FormatException();
        }
        _accounts = accounts;
        _selected = active;
        _loaded = true;
        return;
      } catch (_) {
        throw const AppFailure('保存的账号列表无法读取，请重试；原有信息尚未覆盖');
      }
    }
    Session? legacy;
    final single = prefs.getString('yingyu.session.v1');
    if (single != null) {
      try {
        legacy = Session.fromJson(object(jsonDecode(single)));
      } catch (_) {
        throw const AppFailure('保存的账户信息无法读取，请重新登录');
      }
    } else if (prefs.getBool('yingyu.legacy.checked.v1') != true) {
      final base = prefs.getString('emby_server_url');
      final token = prefs.getString('emby_access_token');
      final user = prefs.getString('emby_user_id');
      if (base != null &&
          token != null &&
          token.isNotEmpty &&
          user != null &&
          user.isNotEmpty) {
        legacy = Session(
          base: normalizeServer(base),
          userId: user,
          token: token,
          username: prefs.getString('emby_username') ?? '',
          deviceId: await deviceId(),
        );
      }
    }
    await _write(
      legacy == null ? [] : [SavedAccount(legacy)],
      legacy == null ? null : accountKey(legacy),
    );
    // The new document is authoritative even if cleanup is interrupted.
    await prefs.remove('yingyu.session.v1');
    await prefs.setBool('yingyu.legacy.checked.v1', true);
  });

  Future<void> _write(List<SavedAccount> accounts, String? selected) async {
    if (!await prefs.setString(
      storageKey,
      jsonEncode({
        'accounts': accounts.map((a) => a.toJson()).toList(),
        'selected': selected,
      }),
    )) {
      throw const AppFailure('账号保存失败，仍保留原来的账号');
    }
    _accounts = accounts;
    _selected = selected;
    _loaded = true;
  }

  Future<void> saveAndSelect(Session session) => _serial(() async {
    final id = accountKey(session);
    final next = List<SavedAccount>.of(_accounts);
    final at = next.indexWhere((a) => a.id == id);
    at < 0 ? next.add(SavedAccount(session)) : next[at] = SavedAccount(session);
    await _write(next, id);
  });

  Future<void> expire(String id) => _serial(() async {
    if (!_accounts.any((a) => a.id == id)) return;
    await _write([
      for (final a in _accounts)
        a.id == id ? SavedAccount(a.session, needsLogin: true) : a,
    ], _selected);
  });

  Future<void> reorder(List<String> ids) => _serial(() async {
    final byId = {for (final account in _accounts) account.id: account};
    if (ids.length != byId.length ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !byId.containsKey(id))) {
      throw const AppFailure('账号列表已变化，请重新排序');
    }
    await _write([for (final id in ids) byId[id]!], _selected);
  });

  Future<void> remove(String id) => _serial(
    () => _write(
      _accounts.where((a) => a.id != id).toList(),
      _selected == id ? null : _selected,
    ),
  );
}
