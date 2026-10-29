import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'accounts.dart';
import 'models.dart';
import 'image_identity.dart';
import 'log_storage.dart';

/// Durable ownership, independent of display-cache LRU and visibility switches.
/// Only opaque hashes, item IDs and ancestor IDs are stored, never credentials.
class ImageReferences {
  ImageReferences({File? file})
    : storage = file == null ? null : LogFileStorage(file, limit: 1000000000);
  final LogFileStorage? storage;
  final _owners = <String, Json>{};
  final _counts = <String, int>{};
  final _pins = <String, int>{};
  final _dirty = <String, Json>{};
  final _pending = <String>{};
  Future<void> _tail = Future.value();
  Future<void> _sweeps = Future.value();
  bool healthy = true;
  String? warning;
  Future<void> Function(Set<String>, bool Function(String))? deleteFiles;
  static String digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String accountId(Session account) => digest(accountKey(account));

  Future<void> load() async {
    try {
      for (final line in await storage?.read() ?? <String>[]) {
        final row = object(jsonDecode(line));
        if (row['pending'] is List) {
          _pending
            ..clear()
            ..addAll((row['pending'] as List).cast<String>());
        } else {
          _apply(row);
        }
      }
    } catch (_) {
      // An incomplete ownership graph cannot authorize image deletion.
      healthy = false;
      warning = '图片引用记录读取失败，已保留图片缓存';
    }
  }

  void _apply(Json row) {
    final owner = row['owner'] as String;
    final old = _owners.remove(owner);
    for (final key in (old?['keys'] as List? ?? const []).cast<String>()) {
      final n = (_counts[key] ?? 1) - 1;
      if (n == 0) {
        _counts.remove(key);
      } else {
        _counts[key] = n;
      }
    }
    if (row['keys'] == null) return;
    _owners[owner] = row;
    for (final key in (row['keys'] as List).cast<String>()) {
      _counts[key] = (_counts[key] ?? 0) + 1;
    }
  }

  void observe(Session account, Iterable<MediaItem> items) {
    final accountHash = accountId(account);
    for (final item in items) {
      if (item.id.isEmpty) continue;
      SharedImageIdentity.remember(account, item);
      final owner = '$accountHash:${item.id}';
      final keys = <String>{
        ...?(_owners[owner]?['keys'] as List?)?.cast<String>(),
      };
      void include(MediaItem image) {
        for (final type in ['Primary', 'Backdrop/0', 'Thumb']) {
          final backdrop = type == 'Backdrop/0', thumbnail = type == 'Thumb';
          // Untagged, unidentified legacy URLs cannot safely be reconstructed.
          final tag = thumbnail
              ? '${object(image.data['ImageTags'])['Thumb'] ?? ''}'
              : backdrop
              ? image.backdropTag
              : image.imageTag;
          if (thumbnail && tag.isEmpty) continue;
          if (tag.isEmpty && SharedImageIdentity.work(image) == null) continue;
          final url =
              '${account.base.toString().replaceFirst(RegExp(r'/+$'), '')}/Items/${Uri.encodeComponent(image.id)}/Images/$type';
          final source = Uri.parse(url)
              .replace(
                queryParameters: {
                  'api_key': account.token,
                  'maxWidth': thumbnail
                      ? '640'
                      : backdrop
                      ? '1280'
                      : '360',
                  'quality': '85',
                  'tag': tag,
                },
              )
              .toString();
          SharedImageIdentity.register(
            account,
            image,
            source,
            backdrop: backdrop,
            thumbnail: thumbnail,
          );
          keys.add(digest(SharedImageIdentity.key(source, artwork: backdrop)));
          // Protect/clean existing tagged pre-TMDB cache keys as well.
          if (tag.isNotEmpty) {
            keys.add(
              digest(
                '${backdrop ? 'artwork:' : ''}yingyu-image:source:v1:${SharedImageIdentity.sourceKey(source)}',
              ),
            );
          }
        }
      }

      include(item);
      final thumbOwner = item.data['ParentThumbItemId'],
          thumbTag = item.data['ParentThumbImageTag'];
      if (thumbOwner is String &&
          thumbOwner.isNotEmpty &&
          thumbTag is String &&
          thumbTag.isNotEmpty) {
        include(
          MediaItem({
            'Id': thumbOwner,
            'Type': thumbOwner == item.data['SeriesId'] ? 'Series' : '',
            'ImageTags': {
              'Thumb': thumbTag,
              if (thumbOwner == item.data['SeriesId'])
                'Primary': item.data['SeriesPrimaryImageTag'] ?? '',
            },
          }),
        );
      }
      final backdropOwner = item.data['ParentBackdropItemId'];
      final backdropTags = item.data['ParentBackdropImageTags'];
      if (backdropOwner is String &&
          backdropOwner.isNotEmpty &&
          backdropTags is List &&
          backdropTags.isNotEmpty) {
        include(
          MediaItem({
            'Id': backdropOwner,
            'Type': backdropOwner == item.data['SeriesId'] ? 'Series' : '',
            if (backdropOwner == item.data['SeriesId'])
              'ImageTags': {
                'Primary': item.data['SeriesPrimaryImageTag'] ?? '',
              },
            'BackdropImageTags': backdropTags,
          }),
        );
      }
      if (item.data['SeriesId'] is String &&
          item.data['SeriesPrimaryImageTag'] is String) {
        include(
          MediaItem({
            'Id': item.data['SeriesId'],
            'Type': 'Series',
            'ImageTags': {'Primary': item.data['SeriesPrimaryImageTag']},
          }),
        );
      }
      final ids = {
        item.id,
        ...[
          item.data['SeriesId'],
          item.data['SeasonId'],
          item.data['ParentId'],
        ].whereType<String>(),
        ...?(item.data['_YingyuLibraryIdsV1'] as List?)?.whereType<String>(),
      }.toList()..sort();
      final sortedKeys = keys.toList()..sort();
      final old = _owners[owner];
      if (old != null &&
          listEquals(old['keys'] as List, sortedKeys) &&
          listEquals(old['ids'] as List, ids)) {
        continue;
      }
      final row = <String, dynamic>{
        'owner': owner,
        'account': accountHash,
        'ids': ids,
        'keys': sortedKeys,
      };
      _apply(row);
      _dirty[owner] = row;
    }
  }

  Future<void> remove(Session account, Set<String> ids) async {
    final accountHash = accountId(account);
    for (final row in _owners.values.toList()) {
      if (row['account'] != accountHash ||
          !(row['ids'] as List).any(ids.contains)) {
        continue;
      }
      _pending.addAll((row['keys'] as List).cast<String>());
      final removed = <String, dynamic>{'owner': row['owner']};
      _apply(removed);
      _dirty[row['owner'] as String] = removed;
    }
    await sweep();
  }

  bool disposable(String hash) =>
      healthy && !_counts.containsKey(hash) && !_pins.containsKey(hash);
  void pin(String key) {
    final hash = digest(key);
    _pins[hash] = (_pins[hash] ?? 0) + 1;
  }

  void unpin(String key) {
    final hash = digest(key), n = (_pins[digest(key)] ?? 1) - 1;
    if (n == 0) {
      _pins.remove(hash);
    } else {
      _pins[hash] = n;
    }
    if (_pending.contains(hash) && disposable(hash)) {
      unawaited(
        sweep().catchError((Object _) {
          warning = '图片清理未完成，下次同步时重试';
        }),
      );
    }
  }

  Future<void> flush() => _tail = _tail.catchError((Object _) {}).then((
    _,
  ) async {
    if (!healthy) return;
    final changes = _dirty.values.toList();
    if (changes.isEmpty && _pending.isEmpty) return;
    try {
      if (storage != null) {
        final rows = [
          ...changes.map(jsonEncode),
          jsonEncode({'pending': _pending.toList()}),
        ];
        if (storage!.rows > _owners.length * 3 + 1000 ||
            !await storage!.file.exists()) {
          await storage!.replace([
            ..._owners.values.map(jsonEncode),
            rows.last,
          ]);
        } else {
          await storage!.append(rows, () => []);
        }
      }
      for (final row in changes) {
        if (identical(_dirty[row['owner']], row)) _dirty.remove(row['owner']);
      }
      warning = null;
    } catch (_) {
      warning = '图片引用记录保存失败，已保留待清理图片';
      rethrow;
    }
  });

  Future<void> sweep() => _sweeps = _sweeps.catchError((Object _) {}).then((
    _,
  ) async {
    await flush(); // Never delete files before the ownership change is durable.
    if (!healthy || deleteFiles == null) return;
    final candidates = _pending.where(disposable).toSet();
    if (candidates.isEmpty) return;
    await deleteFiles!(candidates, disposable);
    _pending.removeWhere(
      (key) =>
          _counts.containsKey(key) ||
          candidates.contains(key) && disposable(key),
    );
    // Replaying a stale pending entry after a crash is harmless and rechecks refs.
  });
}
