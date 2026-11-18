import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Session-only ring of already received raw bytes. Reader and writer each
/// own a file handle so simultaneous I/O cannot move the other one's cursor.
class DiscForwardSpool {
  DiscForwardSpool._(
    this._folder,
    this._read,
    this._write,
    this.start,
    this.size,
  );

  final Directory _folder;
  final RandomAccessFile _read, _write;
  final int start, size;
  Future<void>? _reading, _writing;
  bool _closed = false;

  static Future<DiscForwardSpool> open(String root, int start, int size) async {
    final folder = await Directory(root).createTemp('yingyu-disc-');
    final file = File('${folder.path}/forward.bin');
    RandomAccessFile? reader, writer;
    try {
      writer = await file.open(mode: FileMode.write);
      reader = await file.open();
      // Android keeps the anonymous file alive until both handles close,
      // including process death. It cannot leak into the next playback.
      if (Platform.isAndroid) {
        await file.delete();
        await folder.delete();
      }
      return DiscForwardSpool._(folder, reader, writer, start, size);
    } catch (_) {
      await _dispose(reader, writer, folder);
      rethrow;
    }
  }

  Future<void> append(int offset, Uint8List data) {
    if (_closed) throw const FileSystemException('原盘临时缓存已关闭');
    return _writing = () async {
      final at = (offset - start) % size;
      final first = math.min(size - at, data.length);
      await _write.setPosition(at);
      await _write.writeFrom(data, 0, first);
      if (first < data.length) {
        await _write.setPosition(0);
        await _write.writeFrom(data, first);
      }
    }();
  }

  Future<void> readInto(int offset, Uint8List out, int from, int count) {
    if (_closed) throw const FileSystemException('原盘临时缓存已关闭');
    return _reading = () async {
      final at = (offset - start) % size;
      final first = math.min(size - at, count);
      await _read.setPosition(at);
      if (await _read.readInto(out, from, from + first) != first) {
        throw const FileSystemException('原盘临时缓存不完整');
      }
      if (first < count) {
        await _read.setPosition(0);
        if (await _read.readInto(out, from + first, from + count) !=
            count - first) {
          throw const FileSystemException('原盘临时缓存不完整');
        }
      }
    }();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in [_reading, _writing]) {
      try {
        await pending;
      } on FileSystemException {
        // The producer or consumer already handles the failed disk operation.
      }
    }
    await _dispose(_read, _write, _folder);
  }

  static Future<void> _dispose(
    RandomAccessFile? reader,
    RandomAccessFile? writer,
    Directory folder,
  ) async {
    for (final file in [reader, writer]) {
      try {
        await file?.close();
      } on FileSystemException {
        // The handle may already have been closed after a storage failure.
      }
    }
    try {
      final file = File('${folder.path}/forward.bin');
      if (await file.exists()) await file.delete();
      if (await folder.exists()) await folder.delete();
    } on FileSystemException {
      // App-private temporary storage is reclaimed by Android.
    }
  }
}
