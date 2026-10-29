import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'host/disc086/new/disc_timestamps.dart' as current;
import 'host/disc086/old/disc_timestamps.dart' as old;

const _old = bool.fromEnvironment('YINGYU_DISC086_OLD');
const _side = _old ? 'old' : 'new';
const _decoder = 'vd-lavc-yingyu-disc-pts';
const _format = 'demuxer-lavf-o';
const _original = 'protocol_whitelist=[file,http],strict=experimental';

class _Options {
  _Options({
    String format = _original,
    String decoder = 'no',
    this.beforeRead,
    this.beforeCommand,
  }) : values = {_format: format, _decoder: decoder};

  final Map<String, String> values;
  final Future<void> Function(String)? beforeRead;
  final Future<void> Function(List<String>, _Options)? beforeCommand;
  final commands = <List<String>>[];
  final reads = <String>[];

  Future<String> read(String key) async {
    reads.add(key);
    await beforeRead?.call(key);
    return values[key.replaceFirst('options/', '')]!;
  }

  Future<void> command(List<String> args) async {
    commands.add([...args]);
    await beforeCommand?.call(args, this);
    if (args.first == 'set') {
      values[args[1]] = args[2];
    } else if (args[2] == 'append') {
      final old = values[args[1]]!;
      values[args[1]] = old.isEmpty ? args.last : '$old,${args.last}';
    } else {
      values[args[1]] = values[args[1]]!
          .split(',')
          .where((part) => !part.startsWith('fflags='))
          .join(',');
    }
  }
}

void main() {
  final prepareFactory = _old
      ? () => old.DiscTimestampSetup().prepare
      : () => current.DiscTimestampSetup().prepare;

  test('$_side ordinary initial does not query or write options', () async {
    final io = _Options();
    await prepareFactory()(disc: false, read: io.read, command: io.command);
    expect(io.commands, isEmpty);
    expect(io.reads, isEmpty);
  });

  test(
    '$_side validated disc opts in and preserves existing format map',
    () async {
      final io = _Options();
      await prepareFactory()(disc: true, read: io.read, command: io.command);
      expect(io.values[_format], '$_original,fflags=+genpts');
      expect(io.values[_decoder], 'yes');
    },
  );

  test('$_side explicit flags remain while copy protection opts in', () async {
    const original = 'fflags=+discardcorrupt,protocol_whitelist=[file,http]';
    final io = _Options(format: original);
    await prepareFactory()(disc: true, read: io.read, command: io.command);
    expect(io.values[_format], original);
    expect(io.values[_decoder], 'yes');
  });

  test(
    '$_side concurrent repeated preparation writes each change once',
    () async {
      final io = _Options();
      final prepare = prepareFactory();
      await Future.wait([
        prepare(disc: true, read: io.read, command: io.command),
        prepare(disc: true, read: io.read, command: io.command),
      ]);
      expect(io.commands, [
        ['change-list', _format, 'append', 'fflags=+genpts'],
        ['set', _decoder, 'yes'],
      ]);
    },
  );

  test('$_side ordinary next load restores both exact snapshots', () async {
    final io = _Options();
    final prepare = prepareFactory();
    await prepare(disc: true, read: io.read, command: io.command);
    await prepare(disc: false, read: io.read, command: io.command);
    expect(io.values, {_format: _original, _decoder: 'no'});
  });

  test(
    '$_side original decoder yes is preserved after ordinary restore',
    () async {
      final io = _Options(decoder: 'yes');
      final prepare = prepareFactory();
      await prepare(disc: true, read: io.read, command: io.command);
      await prepare(disc: false, read: io.read, command: io.command);
      expect(io.values, {_format: _original, _decoder: 'yes'});
    },
  );

  test('$_side explicit format flags are untouched through restore', () async {
    const original = 'fflags=+discardcorrupt';
    final io = _Options(format: original);
    final prepare = prepareFactory();
    await prepare(disc: true, read: io.read, command: io.command);
    await prepare(disc: false, read: io.read, command: io.command);
    expect(io.values, {_format: original, _decoder: 'no'});
  });

  test(
    '$_side decoder command failure after mutation rolls both back',
    () async {
      final io = _Options(
        beforeCommand: (args, io) async {
          if (args.first == 'set' && args.last == 'yes') {
            io.values[_decoder] = 'yes';
            throw StateError('synthetic set rejected after mutation');
          }
        },
      );
      final result = await prepareFactory()(
        disc: true,
        read: io.read,
        command: io.command,
      );
      expect(result, contains('未启用'));
      expect(io.values, {_format: _original, _decoder: 'no'});
    },
  );

  test('$_side decoder readback mismatch rolls both back', () async {
    var rejectReadback = true;
    final io = _Options(
      beforeCommand: (args, io) async {
        if (args.first == 'set' && args.last == 'yes') {
          io.values[_decoder] = 'no';
        }
      },
      beforeRead: (key) async {
        if (key == 'options/$_decoder' && rejectReadback) {
          rejectReadback = false;
        }
      },
    );
    final prepare = prepareFactory();
    var decoderReads = 0;
    final result = await prepare(
      disc: true,
      read: (key) async {
        if (key == 'options/$_decoder' && ++decoderReads == 2) return 'no';
        return io.read(key);
      },
      command: io.command,
    );
    expect(result, contains('未启用'));
    expect(io.values, {_format: _original, _decoder: 'no'});
  });

  test('$_side format append rejection restores exact original', () async {
    final io = _Options(
      beforeCommand: (args, io) async {
        if (args.first == 'change-list' && args[2] == 'append') {
          io.values[_format] = 'fflags=unexpected';
          throw StateError('synthetic append rejection');
        }
        if (args.first == 'change-list' && args[2] == 'remove') {
          io.values[_format] = _original;
        }
      },
    );
    final result = await prepareFactory()(
      disc: true,
      read: io.read,
      command: io.command,
    );
    expect(result, contains('未启用'));
    expect(io.values, {_format: _original, _decoder: 'no'});
  });

  test(
    '$_side failed decoder rollback keeps snapshot for later restore',
    () async {
      var reject = true;
      final io = _Options(
        beforeCommand: (args, io) async {
          if (!reject || args.first != 'set') return;
          if (args.last == 'yes') io.values[_decoder] = 'yes';
          throw StateError('synthetic decoder command rejection');
        },
      );
      final prepare = prepareFactory();
      await expectLater(
        prepare(disc: true, read: io.read, command: io.command),
        throwsStateError,
      );
      expect(io.values[_format], _original);
      reject = false;
      await prepare(disc: false, read: io.read, command: io.command);
      expect(io.values, {_format: _original, _decoder: 'no'});
    },
  );

  test(
    '$_side failed format rollback retains its snapshot for retry',
    () async {
      var reject = true;
      final io = _Options(
        beforeCommand: (args, io) async {
          if (args.first != 'change-list') return;
          if (reject) {
            io.values[_format] = 'fflags=unexpected';
            throw StateError('synthetic format rejection');
          }
          if (args[2] == 'remove') io.values[_format] = _original;
        },
      );
      final prepare = prepareFactory();
      await expectLater(
        prepare(disc: true, read: io.read, command: io.command),
        throwsStateError,
      );
      reject = false;
      await prepare(disc: false, read: io.read, command: io.command);
      expect(io.values, {_format: _original, _decoder: 'no'});
    },
  );

  test('$_side unreadable decoder snapshot makes no partial change', () async {
    final io = _Options(
      beforeRead: (key) async {
        if (key == 'options/$_decoder') throw StateError('synthetic read');
      },
    );
    final result = await prepareFactory()(
      disc: true,
      read: io.read,
      command: io.command,
    );
    expect(result, contains('未启用'));
    expect(io.commands, isEmpty);
    expect(io.values, {_format: _original, _decoder: 'no'});
  });

  test('$_side unknown decoder value makes no partial change', () async {
    final io = _Options(decoder: 'unknown');
    final result = await prepareFactory()(
      disc: true,
      read: io.read,
      command: io.command,
    );
    expect(result, contains('未启用'));
    expect(io.commands, isEmpty);
    expect(io.values, {_format: _original, _decoder: 'unknown'});
  });

  test(
    '$_side queued ordinary restore waits for in-flight preparation',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final io = _Options(
        beforeCommand: (args, io) async {
          if (args.first == 'change-list' && args[2] == 'append') {
            entered.complete();
            await release.future;
          }
        },
      );
      final prepare = prepareFactory();
      final disc = prepare(disc: true, read: io.read, command: io.command);
      await entered.future;
      final ordinary = prepare(disc: false, read: io.read, command: io.command);
      expect(io.commands.length, 1);
      release.complete();
      await Future.wait([disc, ordinary]);
      expect(io.values, {_format: _original, _decoder: 'no'});
    },
  );

  test(
    '$_side ordinary decoder restore failure also restores format',
    () async {
      var rejectRestore = false;
      final io = _Options(
        beforeCommand: (args, io) async {
          if (rejectRestore && args.first == 'set' && args.last == 'no') {
            throw StateError('synthetic ordinary restore rejection');
          }
        },
      );
      final prepare = prepareFactory();
      await prepare(disc: true, read: io.read, command: io.command);
      rejectRestore = true;
      await expectLater(
        prepare(disc: false, read: io.read, command: io.command),
        throwsStateError,
      );
      expect(io.values[_format], _original);
      rejectRestore = false;
      await prepare(disc: false, read: io.read, command: io.command);
      expect(io.values, {_format: _original, _decoder: 'no'});
    },
  );
}
