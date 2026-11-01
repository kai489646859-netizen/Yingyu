import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/image_references.dart';
import 'package:yingyu/core/image_reference_storage.dart';
import 'package:yingyu/core/log_policy.dart';
import 'package:yingyu/core/models.dart';
import 'core_test.dart' show syntheticSession;

class InterruptedAppendFile implements File {
  InterruptedAppendFile(this.actual);
  final File actual;
  @override
  String get path => actual.path;
  @override
  Directory get parent => actual.parent;
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await actual.writeAsString(
      contents.substring(0, 5),
      mode: mode,
      flush: true,
    );
    throw const FileSystemException('synthetic interrupted append');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late File file;
  final account = syntheticSession();
  final accountHash = ImageReferences.accountId(account);
  String row(String id, String key) => jsonEncode({
    'owner': '$accountHash:$id',
    'account': accountHash,
    'ids': [id],
    'keys': [key],
  });
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('yingyu-review213-');
    file = File('${dir.path}/refs.jsonl');
  });
  tearDown(() => dir.delete(recursive: true));

  test(
    'partial append retry replaces the damaged tail with a complete snapshot',
    () async {
      final storage = ImageReferenceStorage(InterruptedAppendFile(file));
      final first = row('keep', 'shared'), second = row('new', 'new-key');
      await storage.replace([first]);
      await expectLater(
        storage.append([second], () => [first, second]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), '$first\n${second.substring(0, 5)}');
      await storage.append([second], () => [first, second]);
      expect(await file.readAsString(), '$first\n$second\n');
      final reopened = ImageReferences(file: file);
      await reopened.load();
      expect(reopened.healthy, isTrue);
      expect(reopened.disposable('shared'), isFalse);
      expect(reopened.disposable('new-key'), isFalse);
    },
  );

  test(
    'large snapshots allow subsequent incremental saves before compaction',
    () async {
      final storage = ImageReferenceStorage(file, compactBytes: 64);
      final first = row('keep', 'shared');
      await storage.replace([first]);
      var snapshots = 0;
      await storage.append(['{"pending":[]}'], () {
        snapshots++;
        return [first, '{"pending":[]}'];
      });
      expect(snapshots, 0);
      expect(await storage.readRows().toList(), [first, '{"pending":[]}']);
      final second = row('next', 'next-key');
      await storage.append([second], () {
        snapshots++;
        return [first, second, '{"pending":[]}'];
      });
      expect(snapshots, 1);
      expect(await storage.readRows().toList(), [
        first,
        second,
        '{"pending":[]}',
      ]);
    },
  );

  test(
    'failed snapshot preserves old journal and defers cleanup until retry',
    () async {
      final original =
          '${List.filled(1010, row('keep', 'shared')).join('\n')}\n${row('remove', 'orphan')}\n';
      await file.writeAsString(original);
      final refs = ImageReferences(file: file);
      await refs.load();
      final deleted = <String>{};
      refs.deleteFiles = (keys, allowed) async =>
          deleted.addAll(keys.where(allowed));
      final blocked = Directory('${file.path}.tmp');
      await blocked.create();
      await expectLater(
        refs.remove(account, {'remove'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), original);
      expect(deleted, isEmpty);
      await blocked.delete();
      await refs.sweep();
      expect(deleted, {'orphan'});
      final reopened = ImageReferences(file: file);
      await reopened.load();
      expect(reopened.disposable('shared'), isFalse);
    },
  );

  test(
    'pending cleanup survives compaction and restart with shared ownership',
    () async {
      await file.writeAsString(
        '${List.filled(1010, row('keep', 'shared')).join('\n')}\n${row('remove', 'orphan')}\n',
      );
      final refs = ImageReferences(file: file);
      await refs.load();
      await refs.remove(account, {'remove'});
      final reopened = ImageReferences(file: file);
      await reopened.load();
      final deleted = <String>{};
      reopened.deleteFiles = (keys, allowed) async =>
          deleted.addAll(keys.where(allowed));
      await reopened.sweep();
      expect(deleted, {'orphan'});
      expect(reopened.disposable('shared'), isFalse);
    },
  );

  test(
    'invalid UTF8 and JSON never authorize cleanup or rewrite evidence',
    () async {
      for (final bytes in [
        [...utf8.encode('${row('keep', 'shared')}\n'), 0xff, 10],
        utf8.encode('${row('keep', 'shared')}\n{"broken":true}\n'),
      ]) {
        await file.writeAsBytes(bytes);
        final refs = ImageReferences(file: file);
        await refs.load();
        expect(refs.healthy, isFalse);
        expect(refs.disposable('unknown'), isFalse);
        await refs.flush();
        expect(await file.readAsBytes(), bytes);
      }
    },
  );

  test(
    'large ownership journal keeps older shared references after restart',
    () async {
      final content = StringBuffer('${row('keep', 'shared')}\n');
      final repeated = '${row('other', 'other-key')}\n';
      while (content.length <= logStorageBytes + 1024) {
        content.write(repeated);
      }
      content.writeln(row('remove', 'shared'));
      await file.writeAsString(content.toString());
      final refs = ImageReferences(file: file);
      await refs.load();
      final deleted = <String>{};
      refs.deleteFiles = (keys, allowed) async =>
          deleted.addAll(keys.where(allowed));
      await refs.remove(account, {'remove'});
      expect(refs.healthy, isTrue);
      expect(refs.disposable('shared'), isFalse);
      expect(deleted, isNot(contains('shared')));
    },
  );

  test(
    'byte compaction persists the complete graph rather than an empty snapshot',
    () async {
      final content = StringBuffer();
      var i = 0;
      while (content.length < logStorageBytes - 128) {
        final line = '${row('item-${i++}', 'shared')}\n';
        if (content.length + line.length >= logStorageBytes) break;
        content.write(line);
      }
      await file.writeAsString(content.toString());
      final refs = ImageReferences(file: file);
      await refs.load();
      refs.observe(account, [
        MediaItem({
          'Id': 'new',
          'ImageTags': {'Primary': 'tag'},
        }),
      ]);
      await refs.flush();
      final reopened = ImageReferences(file: file);
      await reopened.load();
      expect(reopened.healthy, isTrue);
      expect(reopened.disposable('shared'), isFalse);
      expect(await file.length(), greaterThan(0));
    },
  );

  test(
    'unfinished ownership append disables deletion without truncating evidence',
    () async {
      final content = '${row('keep', 'shared')}\n{"owner":"unfinished';
      await file.writeAsString(content);
      final refs = ImageReferences(file: file);
      await refs.load();
      expect(refs.healthy, isFalse);
      expect(refs.disposable('unknown'), isFalse);
      expect(await file.readAsString(), content);
    },
  );
}
