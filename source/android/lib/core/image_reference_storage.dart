import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// Ownership is a complete graph, not a diagnostic history whose tail suffices.
/// Keep the existing JSONL format, streaming every record on restore.
class ImageReferenceStorage {
  ImageReferenceStorage(this.file, {this.compactBytes = 8 * 1024 * 1024});
  final File file;
  final int compactBytes;
  int rows = 0;
  int storedBytes = 0;
  int _snapshotBytes = 0;
  bool _appendFailed = false;

  Stream<String> readRows() async* {
    if (!await file.exists()) return;
    rows = 0;
    storedBytes = 0;
    var lastByte = -1;
    Stream<List<int>> chunks() async* {
      await for (final chunk in file.openRead()) {
        storedBytes += chunk.length;
        if (chunk.isNotEmpty) lastByte = chunk.last;
        yield chunk;
      }
      // An interrupted row may describe a live reference. Do not truncate it
      // and silently authorize deletion using an incomplete graph.
      if (lastByte != -1 && lastByte != 10) {
        throw const FormatException('Incomplete image ownership record');
      }
    }

    await for (final line
        in chunks().transform(utf8.decoder).transform(const LineSplitter())) {
      rows++;
      yield line;
    }
  }

  Future<void> append(
    List<String> entries,
    List<String> Function() snapshot,
  ) async {
    if (entries.isEmpty) return;
    final content = '${entries.join('\n')}\n';
    final size = utf8.encode(content).length;
    // Large libraries must not rewrite their entire graph on every page save.
    if (_appendFailed ||
        storedBytes + size > math.max(compactBytes, _snapshotBytes * 2)) {
      await replace(snapshot());
      return;
    }
    try {
      await file.writeAsString(content, mode: FileMode.append, flush: true);
      rows += entries.length;
      storedBytes += size;
    } catch (_) {
      // A short write must be replaced, never followed by another append.
      _appendFailed = true;
      rethrow;
    }
  }

  Future<void> replace(List<String> entries) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final content = entries.isEmpty ? '' : '${entries.join('\n')}\n';
    await temporary.writeAsString(content, flush: true);
    await temporary.rename(file.path);
    rows = entries.length;
    storedBytes = utf8.encode(content).length;
    _snapshotBytes = storedBytes;
    _appendFailed = false;
  }
}
