import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/log_storage.dart';

class LogPreferences extends InMemorySharedPreferencesStore {
  LogPreferences(super.values) : super.withData();
  int logListWrites = 0;
  @override
  Future<bool> setValue(String type, String key, Object value) {
    if (key.endsWith(DiagnosticLog.entriesKey)) logListWrites++;
    return super.setValue(type, key, value);
  }
}

class HeldJournal extends LogFileStorage {
  HeldJournal(super.file);
  Completer<void>? entered, gate;
  bool fail = false;
  @override
  Future<void> append(
    List<String> entries,
    List<String> Function() snapshot,
  ) async {
    entered?.complete();
    await gate?.future;
    await super.append(entries, snapshot);
    if (fail) throw const FileSystemException('synthetic interrupted append');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp(
      'yingyu-log-journal-test-',
    );
  });
  tearDown(() async {
    expect(directory.absolute.path, contains('yingyu-log-journal-test-'));
    await directory.delete(recursive: true);
  });
  test(
    '5000 old rows migrate once; subsequent saves append only new records',
    () async {
      final old = List.generate(
        5000,
        (i) => LogEntry(
          DateTime.utc(2026),
          '0.5.5',
          LogArea.app,
          LogLevel.info,
          'old $i ${'x' * 160}',
        ).encode(),
      );
      final platform = LogPreferences({
        'flutter.${DiagnosticLog.entriesKey}': old,
      });
      SharedPreferencesStorePlatform.instance = platform;
      final prefs = await SharedPreferences.getInstance();
      final journal = LogFileStorage(File('${directory.path}/history.jsonl'));
      final log = await DiagnosticLog.open(prefs, storage: journal);
      expect(log.entries, hasLength(5000));
      expect(prefs.containsKey(DiagnosticLog.entriesKey), false);
      final before = await journal.file.length();
      var expectedBytes = 0;
      for (var i = 0; i < 20; i++) {
        log.add(LogArea.app, 'new $i');
        expectedBytes += log.entries.last.encode().length + 1;
        await log.flush();
      }
      expect(await journal.file.length() - before, expectedBytes);
      expect(platform.logListWrites, 0);
      final restored = await DiagnosticLog.open(
        prefs,
        storage: LogFileStorage(journal.file),
      );
      expect(restored.entries.length, 5020);
      expect(restored.entries.first.message, startsWith('old 0 '));
      expect(restored.entries.last.message, 'new 19');
      log.dispose();
      restored.dispose();
    },
  );
  test(
    'journal compacts a bounded history and explicit clear survives reopening',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final journal = LogFileStorage(
        File('${directory.path}/history.jsonl'),
        limit: 4,
      );
      await journal.replace(['one', 'two', 'three', 'four']);
      await journal.append([
        'five',
        'six',
        'seven',
        'eight',
      ], () => ['five', 'six', 'seven', 'eight']);
      await journal.append(['nine'], () => ['six', 'seven', 'eight', 'nine']);
      expect(await journal.read(), ['six', 'seven', 'eight', 'nine']);
      final log = await DiagnosticLog.open(prefs, storage: journal);
      log.add(LogArea.app, 'later');
      await log.flush();
      await log.clear();
      expect(await journal.file.length(), 0);
      final restored = await DiagnosticLog.open(
        prefs,
        storage: LogFileStorage(journal.file),
      );
      expect(restored.entries, isEmpty);
      log.dispose();
      restored.dispose();
    },
  );
  test(
    'interrupted trailing record does not discard completed history',
    () async {
      final file = File('${directory.path}/history.jsonl');
      final entry = LogEntry(
        DateTime.utc(2026),
        '0.5.5',
        LogArea.app,
        LogLevel.info,
        'kept',
      ).encode();
      await file.writeAsString('$entry\n{"unfinished');
      final journal = LogFileStorage(file);
      expect(await journal.read(), [entry]);
      expect(await file.readAsString(), '$entry\n');
    },
  );
  test(
    'failed partial append retries by replacement without duplicates',
    () async {
      final journal = HeldJournal(File('${directory.path}/history.jsonl'));
      final prefs = await SharedPreferences.getInstance();
      final log = await DiagnosticLog.open(prefs, storage: journal);
      journal.fail = true;
      log.add(LogArea.app, 'once');
      await log.flush();
      expect(log.storageError, isNotNull);
      journal.fail = false;
      log.add(LogArea.app, 'twice');
      await log.flush();
      expect(log.storageError, isNull);
      final restored = await DiagnosticLog.open(
        prefs,
        storage: LogFileStorage(journal.file),
      );
      expect(restored.entries.map((e) => e.message), ['once', 'twice']);
      log.dispose();
      restored.dispose();
    },
  );
  test(
    'clear while an append is in flight cannot resurrect old rows',
    () async {
      final journal = HeldJournal(File('${directory.path}/history.jsonl'));
      final log = await DiagnosticLog.open(
        await SharedPreferences.getInstance(),
        storage: journal,
      );
      journal.entered = Completer<void>();
      journal.gate = Completer<void>();
      log.add(LogArea.app, 'before clear');
      final writing = log.flush();
      await journal.entered!.future;
      final clearing = log.clear();
      journal.gate!.complete();
      await writing;
      await clearing;
      expect(await journal.file.length(), 0);
      log.dispose();
    },
  );
}
