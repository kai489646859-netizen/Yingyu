import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/audio_balance.dart';

class FilterIo {
  String filters = 'scaletempo2';
  String format = 'float';
  final reads = <String>[];
  final writes = <String>[];
  bool rejectOnce = false, brokenRollback = false;
  Future<String> read(String name) async {
    reads.add(name);
    return name == 'af' ? filters : format;
  }

  Future<void> write(String name, String value) async {
    expect(name, 'af');
    writes.add(value);
    if (rejectOnce) {
      rejectOnce = false;
      return;
    }
    if (brokenRollback) {
      filters = '';
      return;
    }
    filters = value;
  }

  Future<AudioBalance> set(
    AudioBalanceControl control,
    AudioBalance value, {
    bool Function()? active,
  }) => control.set(
    value,
    read: read,
    write: write,
    active: active ?? () => true,
  );
}

void main() {
  test('default original sound makes no native reads or writes', () async {
    final io = FilterIo(), control = AudioBalanceControl();
    expect(await io.set(control, AudioBalance.original), AudioBalance.original);
    expect(io.reads, isEmpty);
    expect(io.writes, isEmpty);
  });
  for (final format in ['s16', 'float', 'doublep']) {
    test(
      '$format retains tempo and custom filters across all presets and off',
      () async {
        final io = FilterIo()..format = format;
        final graph = 'volume=0.7,pan=stereo|c0=c0|c1=c1';
        final original =
            'scaletempo2,@custom:lavfi=graph=%${utf8.encode(graph).length}%$graph';
        io.filters = original;
        final control = AudioBalanceControl();
        for (final mode in [
          ...AudioBalance.values.skip(1),
          AudioBalance.original,
        ]) {
          expect(await io.set(control, mode), mode);
          expect(
            audioFilterEntries(io.filters).take(2),
            audioFilterEntries(original),
          );
          expect(
            audioFilterEntries(
              io.filters,
            ).where((s) => s.startsWith('@yingyu_balance:')).length,
            mode == AudioBalance.original ? 0 : 1,
          );
        }
        expect(io.filters, original);
      },
    );
  }
  for (final format in ['spdif-truehd', 'spdif-dts', '', '??']) {
    test(
      '$format does not change output routing or force PCM conversion',
      () async {
        final io = FilterIo()..format = format;
        await expectLater(
          io.set(AudioBalanceControl(), AudioBalance.night),
          throwsA(isA<AppFailure>()),
        );
        expect(io.writes, isEmpty);
        expect(io.filters, 'scaletempo2');
      },
    );
  }
  test(
    'ignored native update fails visibly and restores the full original chain',
    () async {
      final io = FilterIo(), control = AudioBalanceControl();
      await io.set(control, AudioBalance.gentle);
      final original = io.filters;
      io.rejectOnce = true;
      await expectLater(
        io.set(control, AudioBalance.night),
        throwsA(isA<AppFailure>()),
      );
      expect(control.value, AudioBalance.gentle);
      expect(io.filters, original);
      expect(io.writes.last, original);
      await io.set(control, AudioBalance.standard);
      expect(control.value, AudioBalance.standard);
    },
  );
  test('external chain changes are not overwritten', () async {
    final io = FilterIo(), control = AudioBalanceControl();
    await io.set(control, AudioBalance.gentle);
    io.filters = 'scaletempo2,@yingyu_balance:!lavfi=graph=unknown';
    final count = io.writes.length;
    await expectLater(
      io.set(control, AudioBalance.night),
      throwsA(isA<AppFailure>()),
    );
    expect(io.writes.length, count);
  });
  test('unconfirmed rollback remains a real error', () async {
    final io = FilterIo()..brokenRollback = true;
    await expectLater(
      io.set(AudioBalanceControl(), AudioBalance.night),
      throwsA(predicate((e) => e.toString().contains('原音频设置未能恢复'))),
    );
  });
  test(
    'closed or replaced session does not receive a late filter change',
    () async {
      final io = FilterIo();
      await expectLater(
        io.set(
          AudioBalanceControl(),
          AudioBalance.standard,
          active: () => false,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(io.reads, isEmpty);
      expect(io.writes, isEmpty);
    },
  );
  test(
    'filter parser preserves escaped commas, Unicode byte counts, and rejects truncation',
    () {
      const value = '声,音';
      final item = '@other:lavfi=graph=%${utf8.encode(value).length}%$value';
      expect(audioFilterEntries('scaletempo2,$item,volume=2'), [
        'scaletempo2',
        item,
        'volume=2',
      ]);
      for (final invalid in [
        'a,,b',
        'lavfi=graph=%99%short',
        '%x%wrong',
        'a,',
      ]) {
        expect(() => audioFilterEntries(invalid), throwsA(isA<AppFailure>()));
      }
    },
  );
  test(
    'only explicit choices persist; old or corrupt preferences use original sound',
    () async {
      SharedPreferences.setMockInitialValues({
        'yingyu.playback.audioBalance.v1': 'future',
      });
      final prefs = await SharedPreferences.getInstance();
      final store = AppStore(prefs);
      expect(store.audioBalance, AudioBalance.original);
      for (final mode in AudioBalance.values) {
        await store.setAudioBalance(mode);
        expect(AppStore(prefs).audioBalance, mode);
      }
      store.log.dispose();
      store.dispose();
    },
  );
  test(
    '1000 sequential preset changes retain exactly one owned filter and recover original',
    () async {
      final io = FilterIo(), control = AudioBalanceControl();
      for (var i = 0; i < 1000; i++) {
        final mode = AudioBalance.values[i % AudioBalance.values.length];
        await io.set(control, mode);
        final entries = audioFilterEntries(io.filters);
        expect(
          entries.where((s) => s.startsWith('@yingyu_balance:')).length,
          mode == AudioBalance.original ? 0 : 1,
        );
        expect(entries.first, 'scaletempo2');
      }
      await io.set(control, AudioBalance.original);
      expect(io.filters, 'scaletempo2');
    },
  );
  test(
    'late reads after close cannot write filters or commit a preset',
    () async {
      final io = FilterIo(), control = AudioBalanceControl();
      var active = true;
      await expectLater(
        control.set(
          AudioBalance.night,
          read: (key) async {
            final result = await io.read(key);
            active = false;
            return result;
          },
          write: io.write,
          active: () => active,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(io.writes, isEmpty);
      expect(control.value, AudioBalance.original);
    },
  );
  test(
    'failed filter control records recovery stage and keeps later operations usable',
    () async {
      final io = FilterIo()..rejectOnce = true;
      final control = AudioBalanceControl();
      final stages = <String>[];
      await expectLater(
        control.set(
          AudioBalance.gentle,
          read: io.read,
          write: io.write,
          active: () => true,
          event: stages.add,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(stages, contains('阶段=已恢复原设置'));
      await io.set(control, AudioBalance.night);
      expect(control.value, AudioBalance.night);
    },
  );
}
