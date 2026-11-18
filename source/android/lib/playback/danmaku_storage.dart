import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
// The Android path provider is pinned by the application.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

/// Stores only public Bilibili segments and explicitly selected public links.
class DanmakuStorage {
  DanmakuStorage([Future<Directory> Function()? root])
    : _root = root ?? _defaultRoot;

  static final local = DanmakuStorage();
  final Future<Directory> Function() _root;
  Future<void> _writes = Future.value();
  int _generation = 0;
  int get generation => _generation;
  static const _lifetime = Duration(days: 7);
  static const _fileLimit = 4 * 1024 * 1024;

  static Future<Directory> _defaultRoot() async =>
      Directory('${(await getTemporaryDirectory()).path}/danmaku-v2');

  String _name(String key) => sha256.convert(utf8.encode(key)).toString();

  Future<Uint8List?> read(String key) async {
    try {
      final file = File('${(await _root()).path}/${_name(key)}.bin');
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > _fileLimit ||
          DateTime.now().difference(stat.modified) > _lifetime) {
        return null;
      }
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, List<int> bytes, int generation) =>
      _enqueue(() async {
        if (bytes.isEmpty ||
            bytes.length > _fileLimit ||
            generation != _generation) {
          return;
        }
        final root = await (await _root()).create(recursive: true);
        final name = '${root.path}/${_name(key)}.bin';
        final pending = File('$name.tmp');
        try {
          await pending.writeAsBytes(bytes, flush: true);
          await pending.rename(name);
        } finally {
          if (await pending.exists()) await pending.delete();
        }
        final files = <(File, FileStat)>[];
        await for (final entity in root.list(followLinks: false)) {
          if (entity is File && entity.path.endsWith('.bin')) {
            files.add((entity, await entity.stat()));
          }
        }
        files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
        var count = 0, bytesKept = 0;
        for (final (file, stat) in files) {
          if (++count > 512 ||
              (bytesKept += stat.size) > 64 * 1024 * 1024 ||
              DateTime.now().difference(stat.modified) > _lifetime) {
            await file.delete();
          }
        }
      });

  Future<void> remove(String key) => _enqueue(() async {
    final file = File('${(await _root()).path}/${_name(key)}.bin');
    if (await file.exists()) await file.delete();
  });

  Future<bool> clear() {
    _generation++;
    var completed = false;
    return _enqueue(() async {
      final root = await _root();
      if (await root.exists()) {
        await for (final file in root.list(followLinks: false)) {
          if (file is File &&
              RegExp(
                r'[/\\][a-f0-9]{64}\.bin(?:\.tmp)?$',
              ).hasMatch(file.path)) {
            await file.delete();
          }
        }
      }
      completed = true;
    }).then((_) => completed);
  }

  Future<void> _enqueue(Future<void> Function() action) =>
      _writes = _writes.then((_) async {
        try {
          await action();
        } catch (_) {
          // Playback and source selection work with an unavailable cache.
        }
      });
}
