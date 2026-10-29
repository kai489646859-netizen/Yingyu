import 'dart:convert';
import 'models.dart';

/// Image-only identities. These are never item IDs for browsing or playback.
class SharedImageIdentity {
  static final _works = <String, String>{};
  static final _images = <String, String>{};
  static const limit = 20000;
  static String? work(MediaItem item) {
    final kind = switch (item.type) {
      'Movie' => 'movie',
      'Series' => 'tv',
      'Person' => 'person',
      _ => null,
    };
    if (kind == null) return null;
    final ids = object(item.data['ProviderIds']).entries
        .where((e) => e.key.toLowerCase() == 'tmdb')
        .map((e) => e.value.toString().trim())
        .toSet();
    if (ids.length != 1 || !RegExp(r'^[0-9]+$').hasMatch(ids.single)) {
      return null;
    }
    final number = int.tryParse(ids.single);
    return number == null || number <= 0 ? null : '$kind:$number';
  }

  static void _put(Map<String, String> map, String key, String value) {
    map.remove(key);
    map[key] = value;
    while (map.length > limit) {
      map.remove(map.keys.first);
    }
  }

  static String _itemKey(Session account, MediaItem item) =>
      jsonEncode([account.base.toString(), item.id, item.type, item.imageTag]);

  static void remember(Session account, MediaItem item) {
    final known = work(item);
    if (known != null && item.id.isNotEmpty) {
      _put(_works, _itemKey(account, item), known);
    } else if (item.data.containsKey('ProviderIds')) {
      // Explicitly missing/invalid identity retires an earlier association.
      _works.remove(_itemKey(account, item));
    }
  }

  static String register(
    Session account,
    MediaItem item,
    String url, {
    required bool backdrop,
    bool thumbnail = false,
  }) {
    remember(account, item);
    // The fallback serves a series-poster surrogate with the same known image
    // tag. Reused server item IDs or newly corrected metadata cannot inherit it.
    final known = work(item) ?? _works[_itemKey(account, item)];
    final source = sourceKey(url);
    if (known != null && source != null) {
      _put(
        _images,
        source,
        'yingyu-image:tmdb:v1:$known:${thumbnail
            ? 'thumb:640'
            : backdrop
            ? 'backdrop:1280'
            : 'poster:360'}:85',
      );
    } else if (source != null) {
      _images.remove(source);
    }
    return url;
  }

  /// Only our precise, unsigned Emby image route can drop account credentials.
  /// Missing tags retain the old per-URL key unless TMDB identity is known.
  static String? sourceKey(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        !RegExp(
          r'/Items/[^/]+/Images/(Primary|Backdrop/0|Thumb)$',
        ).hasMatch(uri.path) ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      return null;
    }
    final query = uri.queryParametersAll;
    if (query.keys.any(
          (k) => !const {'api_key', 'maxWidth', 'quality', 'tag'}.contains(k),
        ) ||
        query.values.any((v) => v.length != 1)) {
      return null;
    }
    final values = <String, String>{
      for (final k in ['maxWidth', 'quality', 'tag'])
        k: uri.queryParameters[k] ?? '',
    };
    return uri.replace(queryParameters: values).toString();
  }

  static String key(String url, {bool artwork = false}) {
    final source = sourceKey(url);
    final tmdb = source == null ? null : _images[source];
    final tagged =
        source != null &&
        (Uri.parse(source).queryParameters['tag']?.isNotEmpty ?? false);
    final identity = tmdb ?? (tagged ? 'yingyu-image:source:v1:$source' : url);
    return artwork ? 'artwork:$identity' : identity;
  }

  static bool shared(String key) => key.contains('yingyu-image:');
  static void reset() {
    _works.clear();
    _images.clear();
  }
}
