import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/dolby_source.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/dolby_output.dart';

void main() {
  test('only exact Dolby GPU failure messages terminate unsafe mapping', () {
    const error = 'Dolby surface timestamp does not match codec output';
    expect(
      isDolbyOutputFailure('vo/gpu-next/aimagereader', 'error', error),
      isTrue,
    );
    expect(
      isDolbyOutputFailure('vo/gpu/aimagereader', 'error', error),
      isFalse,
    );
    expect(
      isDolbyOutputFailure('vo/gpu-next/aimagereader', 'warn', error),
      isFalse,
    );
    expect(
      isDolbyOutputFailure('vo/gpu-next', 'error', 'Failed rendering frame!'),
      isFalse,
    );
  });
  test('ordinary HDR and a Dolby title do not select the Dolby pipeline', () {
    expect(
      requestsDolbyMapping([
        {'Type': 'Video', 'VideoRangeType': 'HDR10', 'Title': 'Dolby Vision'},
      ]),
      isFalse,
    );
    expect(
      requestsDolbyMapping([
        {'Type': 'Audio', 'DoviProfile': 5},
      ]),
      isFalse,
    );
    expect(requestsDolbyMapping([]), isFalse);
  });
  test(
    'structured Dolby fields select mapping without guessing the profile',
    () {
      for (final fields in [
        {'DoviProfile': 5},
        {'DvProfile': 8},
        {'ExtendedVideoType': 'DolbyVision'},
        {'ExtendedVideoSubType': 'DoviProfile76'},
        {'VideoRangeType': 'DOVIWithHDR10'},
        {'VideoRangeType': 'DOVIWithELHDR10Plus'},
      ]) {
        expect(
          requestsDolbyMapping([
            {'Type': 'Video', ...fields},
          ]),
          isTrue,
        );
      }
      expect(
        requestsDolbyMapping([
          {'Type': 'Video', 'DvProfile': 100, 'VideoRangeType': 'DOVIInvalid'},
        ]),
        isFalse,
      );
    },
  );

  late DolbyOutputSetup setup;
  late Map<String, String> values;
  late List<String> operations;
  late List<String> reads;
  const ordinary = {
    'hwdec': 'auto-safe',
    'vd-lavc-yingyu-dovi': 'no',
    'vo': 'gpu',
    'target-prim': 'auto',
    'target-trc': 'auto',
    'tone-mapping': 'auto',
    'tone-mapping-param': 'default',
    'dither': 'ordered',
    'dither-depth': 'auto',
    'hdr-compute-peak': 'no',
  };
  const mapped = {
    'hwdec': 'auto',
    'vd-lavc-yingyu-dovi': 'yes',
    'vo': 'gpu-next',
    'target-prim': 'bt.709',
    'target-trc': 'bt.1886',
    'tone-mapping': 'bt.2390',
    'tone-mapping-param': '0.5',
    'dither': 'fruit',
    'dither-depth': '8',
    'hdr-compute-peak': 'auto',
  };
  setUp(() {
    setup = DolbyOutputSetup();
    values = Map.of(ordinary);
    operations = [];
    reads = [];
  });
  Future<bool> apply(
    bool enabled, {
    String? reject,
    String? ignore,
    String? unreadable,
  }) => setup.apply(
    requested: enabled,
    originalOutput: 'gpu',
    read: (key) async {
      expect(key, startsWith('options/'));
      reads.add(key);
      if (key == unreadable) throw StateError('synthetic read failure');
      return values[key.substring('options/'.length)]!;
    },
    write: (key, value) async {
      // Every original value must be captured before the first mutation.
      if (operations.isEmpty) {
        expect(
          reads.toSet(),
          containsAll([
            for (final option in ordinary.keys.where((k) => k != 'vo'))
              'options/$option',
          ]),
        );
      }
      operations.add('$key=$value');
      if ('$key=$value' == reject) throw StateError('synthetic failure');
      if ('$key=$value' != ignore) {
        values[key] = key == 'dither-depth'
            ? switch (value) {
                '-1' => 'no',
                '0' => 'auto',
                _ => value,
              }
            : value;
      }
    },
    output: (value) async {
      if (value == 'gpu-next') {
        // This callback selects the VO before it can present a first frame.
        for (final option in mapped.keys.where((k) => k != 'vo')) {
          expect(
            values[option],
            option == 'hwdec' && values['hwdec'] == 'no'
                ? 'no'
                : mapped[option],
          );
        }
      }
      operations.add('vo=$value');
      if ('vo=$value' == reject) throw StateError('synthetic failure');
      values['vo'] = value;
    },
  );
  test(
    'ordinary media neither changes output nor reads native options',
    () async {
      await setup.apply(
        requested: false,
        originalOutput: 'gpu',
        read: (_) async => throw StateError('must not read'),
        write: (_, _) async => throw StateError('must not write'),
        output: (_) async => throw StateError('must not change output'),
      );
      expect(setup.output('gpu'), 'gpu');
    },
  );
  test(
    'Dolby configures the SDR target before VO selection and restores all options',
    () async {
      expect(await apply(true), isTrue);
      expect(values, mapped);
      expect(operations.last, 'vo=gpu-next');
      expect(setup.output('gpu'), 'gpu-next');
      expect(await apply(false), isTrue);
      expect(values, ordinary);
      expect(setup.enabled, isFalse);
    },
  );
  test('repeated Dolby opens do not rebuild the decoder or output', () async {
    await apply(true);
    operations.clear();
    reads.clear();
    expect(await apply(true), isFalse);
    expect(operations, isEmpty);
    expect(reads, isEmpty);
  });
  test('explicit software mode is retained', () async {
    values['hwdec'] = 'no';
    await apply(true);
    expect(values['hwdec'], 'no');
    await apply(false);
    expect(values['hwdec'], 'no');
  });
  for (final originalPeak in ['no', 'auto', 'yes']) {
    test(
      'Dolby permits GPU peak detection then restores $originalPeak exactly',
      () async {
        values['hdr-compute-peak'] = originalPeak;
        final original = Map.of(values);
        await apply(true);
        expect(values['hdr-compute-peak'], 'auto');
        expect(
          operations.indexOf('hdr-compute-peak=auto'),
          lessThan(operations.indexOf('vo=gpu-next')),
        );
        await apply(false);
        expect(values, original);
        expect(setup.enabled, isFalse);
      },
    );
  }
  test('an output failure rolls back mapping and hardware', () async {
    await expectLater(apply(true, reject: 'vo=gpu-next'), throwsStateError);
    expect(values, ordinary);
    expect(setup.enabled, isFalse);
  });
  test('a silently rejected native option is detected and restored', () async {
    await expectLater(apply(true, ignore: 'hwdec=auto'), throwsStateError);
    expect(values, ordinary);
    expect(setup.enabled, isFalse);
  });
  test('failed restore retains the snapshot for a later attempt', () async {
    await apply(true);
    await expectLater(
      apply(false, reject: 'hwdec=auto-safe'),
      throwsStateError,
    );
    expect(setup.enabled, isTrue);
    expect(values, {...ordinary, 'hwdec': 'auto'});
    await apply(false);
    expect(values, ordinary);
    expect(setup.enabled, isFalse);
  });

  test('a failed restore must finish before a later Dolby request', () async {
    await apply(true);
    await expectLater(
      apply(false, reject: 'hwdec=auto-safe'),
      throwsStateError,
    );
    expect(await apply(true), isTrue);
    expect(values, mapped);
    await apply(false);
    expect(values, ordinary);
  });

  test(
    'a rejected peak restore keeps the snapshot for a later attempt',
    () async {
      await apply(true);
      await expectLater(
        apply(false, reject: 'hdr-compute-peak=no'),
        throwsStateError,
      );
      expect(values, {...ordinary, 'hdr-compute-peak': 'auto'});
      expect(setup.enabled, isTrue);
      await apply(false);
      expect(values, ordinary);
      expect(setup.enabled, isFalse);
    },
  );

  test('an ignored peak restore is detected and can be retried', () async {
    await apply(true);
    await expectLater(
      apply(false, ignore: 'hdr-compute-peak=no'),
      throwsStateError,
    );
    expect(values, {...ordinary, 'hdr-compute-peak': 'auto'});
    expect(setup.enabled, isTrue);
    await apply(false);
    expect(values, ordinary);
    expect(setup.enabled, isFalse);
  });

  test('an unavailable peak option fails before any mutation', () async {
    await expectLater(
      apply(true, unreadable: 'options/hdr-compute-peak'),
      throwsStateError,
    );
    expect(operations, isEmpty);
    expect(values, ordinary);
    expect(await apply(false), isFalse);
  });

  test('a missing original option makes no partial output changes', () async {
    await expectLater(
      apply(true, unreadable: 'options/tone-mapping'),
      throwsStateError,
    );
    expect(operations, isEmpty);
    expect(values, ordinary);
    expect(await apply(false), isFalse);
  });

  test(
    'non-default display options are restored instead of reset to defaults',
    () async {
      values.addAll({
        'target-prim': 'bt.2020',
        'target-trc': 'pq',
        'tone-mapping': 'clip',
        'dither': 'no',
        'dither-depth': '10',
      });
      final original = Map.of(values);
      await apply(true);
      expect(values, mapped);
      await apply(false);
      expect(values, original);
    },
  );

  for (final originalDepth in ['-1', '0']) {
    test('dither-depth restores the integer alias $originalDepth', () async {
      values['dither-depth'] = originalDepth;
      await apply(true);
      await apply(false);
      expect(operations, contains('dither-depth=$originalDepth'));
      expect(values['dither-depth'], originalDepth == '-1' ? 'no' : 'auto');
      expect(setup.enabled, isFalse);
    });
  }

  for (final entry in mapped.entries.where(
    (entry) => !{'hwdec', 'vd-lavc-yingyu-dovi', 'vo'}.contains(entry.key),
  )) {
    test('a rejected ${entry.key} restores the entire snapshot', () async {
      await expectLater(
        apply(true, reject: '${entry.key}=${entry.value}'),
        throwsStateError,
      );
      expect(values, ordinary);
      expect(operations, isNot(contains('vo=gpu-next')));
      expect(setup.enabled, isFalse);
    });
    test('an ignored ${entry.key} is detected and restored', () async {
      await expectLater(
        apply(true, ignore: '${entry.key}=${entry.value}'),
        throwsStateError,
      );
      expect(values, ordinary);
      expect(operations, isNot(contains('vo=gpu-next')));
      expect(setup.enabled, isFalse);
    });
  }
}
