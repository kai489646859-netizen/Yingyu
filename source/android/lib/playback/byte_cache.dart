import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
// Public platform dependency already pinned by the application.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';

String playbackCacheHash(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// Raw, independently reusable ranges, not MPV's non-reusable packet dump.
/// Only opaque hashes and offsets go on disk. Quota includes headers and staging
/// files; a serialized queue makes reservations/eviction/writes atomic to readers.
class PlaybackByteCache {
  PlaybackByteCache({Future<Directory> Function()? directory})
    : _directory =
          directory ??
          (() async => Directory(
            '${(await getApplicationSupportDirectory()).path}/yingyu-video-cache-v1',
          ));
  final Future<Directory> Function() _directory;
  Future<Directory>? _root;
  final _entries = <String, _Entry>{};
  Future<void> _tail = Future.value();
  int limitBytes = 0, usedBytes = 0;
  String? warning;
  final Set<String> protected = {};
  final _protections = <String, Set<String>>{};
  final _windows = <String, ({int start, int end})>{};
  bool _loaded = false;
  bool get ready => _loaded;

  Future<T> _serial<T>(Future<T> Function() action) {
    final job = _tail.then((_) => action());
    _tail = job.then<void>((_) {}, onError: (Object _) {});
    return job;
  }

  Future<Directory> _open() async {
    final dir = await (_root ??= _directory());
    if (!_loaded) {
      await dir.create(recursive: true);
      _entries.clear();
      usedBytes = 0;
      await for (final file in dir.list(followLinks: false)) {
        if (file is! File) continue;
        final name = file.uri.pathSegments.last;
        if (!RegExp(r'^[a-f0-9]{64}\.block$').hasMatch(name)) {
          if (RegExp(r'^[a-f0-9]{64}\.partial$').hasMatch(name)) {
            await file.delete();
          }
          continue;
        }
        final stat = await file.stat();
        _entries[name] = _Entry(file, stat.size, stat.modified);
        usedBytes += stat.size;
      }
      final ordered = _entries.entries.toList()
        ..sort((a, b) => a.value.used.compareTo(b.value.used));
      _entries
        ..clear()
        ..addEntries(ordered);
      _loaded = true;
    }
    return dir;
  }

  String _name(String identity, int start) =>
      '${playbackCacheHash([identity, start])}.block';
  bool contains(String identity, int start) {
    final entry = _entries[_name(identity, start)];
    if (entry == null) return false;
    entry.identity = identity;
    entry.start = start;
    return true;
  }

  Future<void> configure(int bytes) => _serial(() async {
    limitBytes = bytes;
    warning = null;
    await _open();
    await _trim(0);
  });

  Future<bool> _trim(int incoming) async {
    if (limitBytes < 0 || usedBytes + incoming <= limitBytes) return true;
    final victims = <MapEntry<String, _Entry>>[];
    var available = usedBytes;
    for (final entry in _entries.entries) {
      if (available + incoming <= limitBytes) break;
      final window = _windows[entry.value.identity];
      if (protected.contains(entry.key) ||
          window != null &&
              entry.value.start >= window.start &&
              entry.value.start < window.end) {
        continue;
      }
      victims.add(entry);
      available -= entry.value.size;
    }
    for (final entry in victims) {
      await entry.value.file.delete();
      usedBytes -= entry.value.size;
      _entries.remove(entry.key);
    }
    return usedBytes + incoming <= limitBytes;
  }

  Future<Uint8List?> read(String identity, int start, int length) => !_loaded
      ? Future.value(null)
      : _serial(() async {
          await _open();
          final name = _name(identity, start),
              entry = _entries[_name(identity, start)];
          if (entry == null) return null;
          entry.identity = identity;
          entry.start = start;
          try {
            final bytes = await entry.file.readAsBytes();
            if (bytes.length != length + 32 ||
                !const _DigestEquality().matches(
                  bytes.sublist(0, 32),
                  sha256.convert(bytes.sublist(32)).bytes,
                )) {
              await entry.file.delete();
              _entries.remove(name);
              usedBytes -= entry.size;
              return null;
            }
            entry.used = DateTime.now();
            _entries.remove(name);
            _entries[name] = entry;
            // Limit filesystem metadata writes without losing in-process LRU order.
            if (entry.used.difference(entry.savedUse) >
                const Duration(minutes: 1)) {
              await entry.file.setLastModified(entry.used);
              entry.savedUse = entry.used;
            }
            return Uint8List.sublistView(bytes, 32);
          } on FileSystemException {
            warning = '播放缓存读取失败，已改为读取片源';
            // Never undercount an unreadable file that still occupies disk space.
            if (!await entry.file.exists() && _entries.remove(name) != null) {
              usedBytes -= entry.size;
            }
            return null;
          }
        });

  Future<bool> write(String identity, int start, List<int> bytes) => !_loaded
      ? Future.value(false)
      : _serial(() async {
          if (limitBytes == 0) return false;
          final root = await _open(), name = _name(identity, start);
          if (_entries.containsKey(name)) return true;
          final size = bytes.length + 32;
          if (!await _trim(size)) return false;
          final file = File('${root.path}/$name'),
              partial = File(
                '${root.path}/${name.replaceAll('.block', '.partial')}',
              );
          try {
            final content = Uint8List(size)
              ..setRange(0, 32, sha256.convert(bytes).bytes)
              ..setRange(32, size, bytes);
            // File.writeAsBytes closes the descriptor even after a failed
            // write; an IOSink.done error must not escape the playback fallback.
            await partial.writeAsBytes(content);
            await partial.rename(file.path);
            _entries[name] = _Entry(file, size, DateTime.now())
              ..identity = identity
              ..start = start;
            usedBytes += size;
            return true;
          } on FileSystemException {
            warning = '播放缓存写入失败或空间不足，本次数据继续直接播放';
            if (await partial.exists()) await partial.delete();
            return false;
          }
        });

  Future<void> clear() => _serial(() async {
    await _open();
    if (protected.isNotEmpty || _windows.isNotEmpty) {
      throw const AppFailure('播放中请先退出视频再清理播放缓存');
    }
    for (final entry in _entries.entries.toList()) {
      await entry.value.file.delete();
      usedBytes -= entry.value.size;
      _entries.remove(entry.key);
    }
    warning = null;
  });

  void protect(String identity, Iterable<int> starts) {
    _protections[identity] = starts
        .map((start) => _name(identity, start))
        .toSet();
    protected
      ..clear()
      ..addAll(_protections.values.expand((value) => value));
  }

  void release([String? identity]) {
    if (identity == null) {
      _windows.clear();
    } else {
      _windows.remove(identity);
    }
    if (identity == null) {
      _protections.clear();
    } else {
      _protections.remove(identity);
    }
    protected
      ..clear()
      ..addAll(_protections.values.expand((value) => value));
  }

  void protectRange(String identity, int start, int end) =>
      _windows[identity] = (start: start, end: end);
}

class _Entry {
  _Entry(this.file, this.size, this.used) : savedUse = used;
  final File file;
  final int size;
  String? identity;
  int start = 0;
  DateTime used, savedUse;
}

class _DigestEquality {
  const _DigestEquality();
  bool matches(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
