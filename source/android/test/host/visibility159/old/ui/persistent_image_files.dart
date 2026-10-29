// These are the public file/path interfaces already pinned by CacheManager.
// ignore: depend_on_referenced_packages
import 'package:file/file.dart' as fs;
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Keep downloaded images out of Android's reclaimable temporary directory.
/// The repository name and relative filenames remain unchanged on upgrade.
class PersistentImageFiles implements FileSystem {
  PersistentImageFiles(this.cacheKey);
  final String cacheKey;
  Future<fs.Directory>? _opening;

  Future<fs.Directory> _open() async {
    const fileSystem = LocalFileSystem();
    final support = await getApplicationSupportDirectory();
    final temporary = await getTemporaryDirectory();
    final target = fileSystem.directory(
      '${support.path}/yingyu-images/$cacheKey',
    );
    final legacy = fileSystem.directory('${temporary.path}/$cacheKey');
    await target.parent.create(recursive: true);
    if (!await target.exists() && await legacy.exists()) {
      // Same app-internal filesystem: rename preserves bytes and last-use dates
      // without a second copy or any HTTP request. Failure leaves legacy intact.
      await legacy.rename(target.path);
    }
    await target.create(recursive: true);
    if (await legacy.exists()) {
      // Resume a partial migration without overwriting a newer persistent file.
      await for (final entry in legacy.list(followLinks: false)) {
        if (entry is! fs.File) continue;
        final destination = target.childFile(entry.basename);
        if (!await destination.exists()) await entry.rename(destination.path);
      }
    }
    return target;
  }

  @override
  Future<fs.File> createFile(String name) async {
    final pending = _opening ??= _open();
    try {
      return (await pending).childFile(name);
    } catch (_) {
      if (identical(_opening, pending)) _opening = null;
      rethrow;
    }
  }
}
