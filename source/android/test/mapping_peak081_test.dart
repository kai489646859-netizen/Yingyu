import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/dolby_output.dart';

// Uses only the complete 0.8.0 helper's apply API. Property IO is synthetic;
// enabling auto makes peak detection eligible, not proof of GPU execution.
void main() {
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

  test(
    'regression081 peak eligibility is set before Dolby VO and restores original no',
    () async {
      final setup = DolbyOutputSetup();
      final values = Map.of(ordinary);
      final operations = <String>[];
      Future<bool> apply(bool requested) => setup.apply(
        requested: requested,
        originalOutput: 'gpu',
        read: (key) async {
          expect(key, startsWith('options/'));
          return values[key.substring('options/'.length)]!;
        },
        write: (key, value) async {
          operations.add('$key=$value');
          values[key] = value;
        },
        output: (value) async {
          if (value == 'gpu-next') {
            expect(values['hdr-compute-peak'], 'auto');
          }
          operations.add('vo=$value');
          values['vo'] = value;
        },
      );

      expect(await apply(true), isTrue);
      expect(values['hdr-compute-peak'], 'auto');
      expect(
        operations.indexOf('hdr-compute-peak=auto'),
        lessThan(operations.indexOf('vo=gpu-next')),
      );
      expect(await apply(false), isTrue);
      expect(values, ordinary);
      expect(values['hdr-compute-peak'], 'no');
      expect(setup.enabled, isFalse);
    },
  );

  test(
    'regression081 ignored peak eligibility is detected before VO selection',
    () async {
      final setup = DolbyOutputSetup();
      final values = Map.of(ordinary);
      final outputs = <String>[];
      await expectLater(
        setup.apply(
          requested: true,
          originalOutput: 'gpu',
          read: (key) async => values[key.substring('options/'.length)]!,
          write: (key, value) async {
            if (key != 'hdr-compute-peak' || value != 'auto') {
              values[key] = value;
            }
          },
          output: (value) async {
            outputs.add(value);
            values['vo'] = value;
          },
        ),
        throwsStateError,
      );
      expect(outputs, isNot(contains('gpu-next')));
      expect(values, ordinary);
      expect(setup.enabled, isFalse);
    },
  );
}
