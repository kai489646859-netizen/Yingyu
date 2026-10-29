import 'dart:convert';
import 'dart:io';
import 'log_policy.dart';

/// App-private append journal. Ordinary saves contain only new redacted rows;
/// they do not serialize the entire history through Android preferences/IPC.
class LogFileStorage {
  LogFileStorage(
    this.file, {
    this.limit = logStorageEntries,
    this.byteLimit = logStorageBytes,
  });
  final File file;
  final int limit;
  final int byteLimit;
  int rows = 0;
  int storedBytes = 0;

  Future<List<String>?> read() async {
    if (!await file.exists()) return null;
    // Read only a bounded tail, even if an older/corrupt journal is oversized.
    final length = await file.length();
    final start = (length - byteLimit).clamp(0, length);
    final bytes = await file
        .openRead(start)
        .fold<List<int>>([], (a, b) => a..addAll(b));
    // A killed process can leave one unfinished append. Retain complete lines
    // and truncate only that incomplete tail before the next append.
    final end = bytes.lastIndexOf(10) + 1;
    if (end != bytes.length) {
      final handle = await file.open(mode: FileMode.append);
      try {
        await handle.truncate(start + end);
      } finally {
        await handle.close();
      }
    }
    final lines = const LineSplitter().convert(
      utf8.decode(
        bytes.sublist(
          start == 0 ? 0 : (bytes.indexOf(10) + 1).clamp(0, end),
          end,
        ),
        allowMalformed: true,
      ),
    );
    rows = lines.length;
    storedBytes = start + end;
    return lines.skip((lines.length - limit).clamp(0, lines.length)).toList();
  }

  Future<void> append(
    List<String> entries,
    List<String> Function() snapshot,
  ) async {
    if (entries.isEmpty) return;
    final content = '${entries.join('\n')}\n';
    final size = utf8.encode(content).length;
    if (rows + entries.length > limit * 2 || storedBytes + size > byteLimit) {
      await replace(snapshot());
      return;
    }
    await file.writeAsString(content, mode: FileMode.append, flush: true);
    rows += entries.length;
    storedBytes += size;
  }

  Future<void> replace(List<String> entries) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final content = entries.isEmpty ? '' : '${entries.join('\n')}\n';
    await temporary.writeAsString(content, flush: true);
    // Same-directory rename commits a compaction/clear without a truncated
    // live file. A failed replacement leaves the preceding journal intact.
    await temporary.rename(file.path);
    rows = entries.length;
    storedBytes = utf8.encode(content).length;
  }
}
