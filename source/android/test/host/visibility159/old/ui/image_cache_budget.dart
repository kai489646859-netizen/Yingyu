import '../core/image_identity.dart';
import '../core/image_references.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../core/models.dart';

const imageGB = 1024 * 1024 * 1024;

class _Entry {
  _Entry(
    this.manager,
    this.file,
    this.bytes,
    this.used,
    this.key, [
    this.order = 0,
  ]);
  final BudgetCacheManager manager;
  final File file;
  final int bytes;
  final DateTime used;
  final String? key;
  final int order;
}

/// One byte budget, two physical directories. Scan once, then update only the
/// file just used. File modification time persists LRU across process restarts.
class ImageCacheBudget extends ChangeNotifier {
  ImageCacheBudget({this.limitBytes = 5 * imageGB, this.autoCleanDays = 0});
  int limitBytes;
  int autoCleanDays;
  String? warning;
  ImageReferences? references;
  Future<void> removeUnreferenced(
    Set<String> hashes,
    bool Function(String) allowed,
  ) => _serial(() async {
    await _load();
    for (final hash in hashes) {
      for (final path in _byImage[hash]?.toList() ?? const <String>[]) {
        final entry = _entries[path];
        if (entry != null && allowed(hash)) {
          await _remove(entry, allowed: () => allowed(hash));
        }
      }
    }
  });
  final _managers = <BudgetCacheManager>[];
  final _entries = <String, _Entry>{};
  final _byImage = <String, Set<String>>{};
  void _indexEntry(_Entry entry, {bool remove = false}) {
    if (entry.key == null) return;
    final hash = ImageReferences.digest(entry.key!);
    if (remove) {
      _byImage[hash]?.remove(entry.file.path);
      if (_byImage[hash]?.isEmpty == true) _byImage.remove(hash);
    } else {
      _byImage.putIfAbsent(hash, () => {}).add(entry.file.path);
    }
  }

  Future<void> _tail = Future.value();
  bool _loaded = false;
  int _bytes = 0;
  int _useSequence = 0;
  DateTime _nextExpirySweep = DateTime.fromMillisecondsSinceEpoch(0);
  int get usedBytes => _bytes;

  Future<void> initialize() => _loaded
      ? _tail
      : _serial(() async {
          await _load();
          await _trim();
        });

  Future<void> _serial(Future<void> Function() work) {
    final next = _tail.then((_) async {
      final previousBytes = _bytes, previousWarning = warning;
      try {
        await work();
        warning = null;
      } catch (e) {
        warning = '图片缓存：${safeError(e)}';
        rethrow;
      } finally {
        if (_bytes != previousBytes || warning != previousWarning) {
          notifyListeners();
        }
      }
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _load() async {
    if (_loaded) return;
    final found = <String, _Entry>{};
    for (final manager in _managers) {
      // Await the repository opened by CacheStore, without a second open.
      await manager.store.retrieveCacheData('__image_quota_initialization__');
      final keys = <String, String>{};
      for (final row in await manager.config.repo.getAllObjects()) {
        final file = await manager.config.fileSystem.createFile(
          row.relativePath,
        );
        keys[file.path] = row.key;
      }
      final directory = await manager.directory();
      if (!await directory.exists()) continue;
      await for (final file in directory.list(followLinks: false)) {
        if (file is! File) continue;
        final stat = await file.stat();
        found[file.path] = _Entry(
          manager,
          file,
          stat.size,
          stat.modified,
          keys[file.path],
        );
      }
    }
    _entries.addAll(found);
    for (final entry in found.values) {
      _indexEntry(entry);
    }
    _bytes = found.values.fold(0, (sum, e) => sum + e.bytes);
    _loaded = true;
  }

  Future<void> _remove(_Entry entry, {bool Function()? allowed}) async {
    // 3.4.1 removes relative file paths. Delete the configured absolute file
    // explicitly, including orphan files left by earlier count-based eviction.
    final exists = await entry.file.exists();
    if (allowed?.call() == false) return;
    if (exists) await entry.file.delete();
    if (entry.key != null) await entry.manager.removeFile(entry.key!);
    final removed = _entries.remove(entry.file.path);
    if (removed != null) _indexEntry(removed, remove: true);
    if (removed != null) _bytes -= removed.bytes;
  }

  Future<void> _trim({String? protect}) async {
    final now = DateTime.now();
    if (usedBytes <= limitBytes && now.isBefore(_nextExpirySweep)) return;
    var total = usedBytes;
    final oldest = _entries.values.toList()
      ..sort((a, b) {
        if (a.manager.isArtwork != b.manager.isArtwork) {
          return a.manager.isArtwork ? -1 : 1;
        }
        final byTime = a.used.compareTo(b.used);
        if (byTime != 0) return byTime;
        final byUse = a.order.compareTo(b.order);
        return byUse != 0 ? byUse : a.file.path.compareTo(b.file.path);
      });
    for (final entry in oldest) {
      if (entry.file.path == protect) continue;
      // Do not evict a wall poster to protect a newly delivered backdrop. Its
      // bounded (<=4 MB) in-use file may exceed the budget until the next trim.
      if (!entry.manager.isArtwork &&
          protect != null &&
          _entries[protect]?.manager.isArtwork == true &&
          total > limitBytes) {
        break;
      }
      final expiredArtwork =
          autoCleanDays > 0 &&
          entry.manager.isArtwork &&
          now.difference(entry.used) >= Duration(days: autoCleanDays);
      // Retain wall posters while space permits. Reclaim artwork first, using
      // persisted last-use time within each category, not download time.
      if (total <= limitBytes && !expiredArtwork) continue;
      await _remove(entry);
      total -= entry.bytes;
    }
    _nextExpirySweep = now.add(const Duration(hours: 12));
  }

  Future<void> setLimit(int bytes) => _serial(() async {
    if (bytes <= 0) throw const AppFailure('缓存上限无效');
    limitBytes = bytes;
    await _load();
    await _trim();
  });

  Future<void> setAutoCleanDays(int days) => _serial(() async {
    if (!const [0, 15, 30, 60].contains(days)) {
      throw const AppFailure('自动清理周期无效');
    }
    autoCleanDays = days;
    _nextExpirySweep = DateTime.fromMillisecondsSinceEpoch(0);
    await _load();
    await _trim();
  });

  Future<void> record(BudgetCacheManager manager, FileInfo info, String key) =>
      _serial(() async {
        await _load();
        final file = File(info.file.path);
        if (!await file.exists()) return;
        final now = DateTime.now();
        await file.setLastModified(now);
        final length = _entries[file.path]?.bytes ?? await file.length();
        if (_entries[file.path] case final _Entry previous) {
          _indexEntry(previous, remove: true);
        }
        _bytes += length - (_entries[file.path]?.bytes ?? 0);
        _entries[file.path] = _Entry(
          manager,
          file,
          length,
          now,
          key,
          ++_useSequence,
        );
        _indexEntry(_entries[file.path]!);
        await _trim(protect: file.path);
      });

  Future<void> clear(BudgetCacheManager manager) => _serial(() async {
    await _load();
    for (final entry
        in _entries.values.where((e) => e.manager == manager).toList()) {
      await _remove(entry);
    }
    await manager.clearMetadata();
  });
}

class BudgetCacheManager extends CacheManager {
  BudgetCacheManager(
    super.config,
    this.budget, {
    this.isArtwork = false,
    this.reuseFrom = const [],
  }) {
    budget._managers.add(this);
  }
  final ImageCacheBudget budget;
  final bool isArtwork;
  final List<CacheManager> reuseFrom;
  Map<String, CacheObject>? _legacyImages;
  Future<void> _migration = Future.value();

  Future<FileInfo?> sharedFile(String url, String key) async {
    final cached = await super.getFileFromCache(key);
    if (cached != null) return cached;
    final shared = SharedImageIdentity.shared(key);
    if (!shared && reuseFrom.isEmpty) return null;
    FileInfo? found;
    final pending = _migration.then((_) async {
      found = await super.getFileFromCache(key);
      if (found != null) return;
      // Serialize exact-key local reuse with migration, so simultaneous cards
      // create only one owned copy. Peer reads never start an HTTP request.
      for (final peer in reuseFrom) {
        try {
          final cached = peer is BudgetCacheManager
              ? await peer.sharedFile(url, key)
              : await peer.getFileFromCache(key);
          if (cached == null ||
              !await cached.file.exists() ||
              await cached.file.length() > 4 * 1024 * 1024) {
            continue;
          }
          final bytes = await cached.file.readAsBytes();
          if (bytes.length > 4 * 1024 * 1024) continue;
          await putFile(
            url,
            bytes,
            key: key,
            maxAge: const Duration(days: 36500),
          );
          found = await super.getFileFromCache(key);
          if (found != null) return;
        } catch (_) {
          /* A concurrently cleared peer is optional. */
        }
      }
      if (!shared) return;
      if (_legacyImages == null) {
        await store.retrieveCacheData('__shared_image_migration__');
        _legacyImages = {};
        for (final row in await config.repo.getAllObjects()) {
          if (row.key != row.url &&
              row.key != 'artwork:${row.url}' &&
              !row.key.startsWith('yingyu-image:source:v1:') &&
              !row.key.startsWith('artwork:yingyu-image:source:v1:')) {
            continue;
          }
          final source = SharedImageIdentity.sourceKey(row.url);
          if (source != null) _legacyImages![source] = row;
        }
      }
      final source = SharedImageIdentity.sourceKey(url);
      if (source == null) return;
      final prefix = isArtwork ? 'artwork:' : '';
      // A fallback image may have been downloaded after the one-time legacy
      // scan, before a normal metadata refresh supplied its TMDB ID.
      final old =
          await config.repo.get('${prefix}yingyu-image:source:v1:$source') ??
          await config.repo.get('$prefix$url') ??
          _legacyImages![source];
      if (old == null) return;
      final file = await config.fileSystem.createFile(old.relativePath);
      if (!await file.exists()) return;
      // Point the canonical record at the existing file, then retire its old
      // metadata. Both SQLite and the pinned JSON repository support this;
      // changing a record's key in place leaves a stale JSON in-memory alias.
      await store.putFile(
        CacheObject(
          url,
          key: key,
          relativePath: old.relativePath,
          validTill: old.validTill,
          eTag: old.eTag,
          length: old.length,
          touched: old.touched,
        ),
      );
      if (old.id != null) await config.repo.delete(old.id!);
      store.emptyMemoryCache();
      _legacyImages!.remove(source);
      found = await super.getFileFromCache(key);
    });
    _migration = pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await pending;
    return found;
  }

  Future<Directory> directory() async => Directory(
    (await config.fileSystem.createFile('.quota-location')).parent.path,
  );

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    final effectiveKey = key ?? url;
    final refs = budget.references;
    refs?.pin(effectiveKey);
    try {
      final cached = await sharedFile(url, effectiveKey);
      if (cached != null && await cached.file.exists()) {
        // A complete local file never needs HTTP validation just to be displayed.
        // Let pixels through before quota bookkeeping, which can scan on startup.
        yield cached;
        try {
          await budget.record(this, cached, effectiveKey);
        } catch (_) {
          /* Settings exposes the quota failure; the cached image stays usable. */
        }
        return;
      }
      try {
        await budget.initialize();
      } catch (_) {
        /* Settings exposes the failure. */
      }
      await for (final response in super.getFileStream(
        url,
        key: key,
        headers: headers,
        withProgress: withProgress,
      )) {
        if (response is FileInfo) {
          try {
            await budget.record(this, response, key ?? url);
          } catch (_) {
            /* Show the real quota warning in Settings; retain the image. */
          }
        }
        yield response;
      }
    } finally {
      refs?.unpin(effectiveKey);
    }
  }

  Future<void> clearMetadata() async {
    await _migration;
    _legacyImages = null;
    await super.emptyCache();
  }

  @override
  Future<void> emptyCache() => budget.clear(this);
}
