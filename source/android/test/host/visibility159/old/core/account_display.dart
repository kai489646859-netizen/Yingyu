import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'accounts.dart';
import 'models.dart';

class AccountDisplay {
  const AccountDisplay({this.alias = '', required this.color});
  final String alias;
  final int color;
  String name(Session session) => alias.isEmpty ? accountName(session) : alias;
}

/// Local presentation only. Neither login names nor authentication are edited.
class AccountDisplays {
  AccountDisplays(this.prefs);
  final SharedPreferences prefs;
  static const colorCount = 6;
  final _loaded = <String, AccountDisplay>{};
  Future<void> _tail = Future.value();
  String _key(Session session) =>
      'yingyu.account-display.v1.${accountKey(session)}';

  AccountDisplay defaults(Session session) {
    final hash = accountKey(
      session,
    ).codeUnits.fold(0, (value, c) => (value * 31 + c) & 0x7fffffff);
    return AccountDisplay(color: hash % colorCount);
  }

  AccountDisplay read(Session session) =>
      _loaded.putIfAbsent(_key(session), () {
        try {
          final raw = prefs.getString(_key(session));
          if (raw == null) return defaults(session);
          final value = object(jsonDecode(raw));
          final alias = value['alias'] as String;
          final color = value['color'] as int;
          if (alias.length > 80 || color < 0 || color >= colorCount) {
            return defaults(session);
          }
          return AccountDisplay(alias: alias, color: color);
        } catch (_) {
          return defaults(session);
        }
      });

  Future<void> save(Session session, String alias, int color) {
    final key = _key(session);
    final clean = alias.trim();
    final result = _tail.then((_) async {
      if (clean.length > 80 || color < 0 || color >= colorCount) {
        throw const AppFailure('账号备注或头像颜色无效');
      }
      if (!await prefs.setString(
        key,
        jsonEncode({'alias': clean, 'color': color}),
      )) {
        throw const AppFailure('账号备注未能保存，请重试');
      }
      _loaded[key] = AccountDisplay(alias: clean, color: color);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
