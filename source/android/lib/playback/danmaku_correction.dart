import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Corrections are direct public episode links, independent of segment cache.
class DanmakuCorrections {
  const DanmakuCorrections(this.prefs);
  final SharedPreferences prefs;
  static const preference = 'danmaku.corrections.v1';
  static const limit = 512;

  static String key(String server, String user, String item) =>
      sha256.convert(utf8.encode(jsonEncode([server, user, item]))).toString();

  Map<String, String> _read() {
    try {
      final raw = prefs.getString(preference);
      if (raw == null || raw.length > 256 * 1024) return {};
      final result = jsonDecode(raw);
      return {
        if (result is Map)
          for (final item in result.entries.take(limit))
            if (item.key is String &&
                item.value is String &&
                (item.key as String).length == 64 &&
                (item.value as String).length <= 320)
              item.key as String: item.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  String? lookup(String key) => _read()[key];

  Future<bool> save(String key, String? link) async {
    final items = _read()..remove(key);
    if (link != null) {
      if (link.isEmpty || link.length > 320) return false;
      items[key] = link;
    }
    while (items.length > limit) {
      items.remove(items.keys.first);
    }
    try {
      return await prefs.setString(preference, jsonEncode(items));
    } catch (_) {
      return false;
    }
  }
}
