import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/dolby_output.dart';

void main() {
  const original = {
    'hwdec': 'auto-safe',
    'vd-lavc-yingyu-dovi': 'no',
    'target-prim': 'auto',
    'target-trc': 'auto',
    'tone-mapping': 'auto',
    'tone-mapping-param': 'default',
    'dither': 'ordered',
    'dither-depth': 'auto',
    'hdr-compute-peak': 'no',
  };
  test(
    'regression082 reference knee is ready before VO and restores default',
    () async {
      final setup = DolbyOutputSetup(), values = Map.of(original);
      Future<void> apply(bool requested) async => setup.apply(
        requested: requested,
        originalOutput: 'gpu',
        read: (key) async => values[key.replaceFirst('options/', '')]!,
        write: (key, value) async => values[key] = value,
        output: (value) async {
          if (value == 'gpu-next') expect(values['tone-mapping-param'], '0.5');
        },
      );
      await apply(true);
      await apply(false);
      expect(values, original);
    },
  );
  test('regression082 ignored knee is detected before VO selection', () async {
    final setup = DolbyOutputSetup(), values = Map.of(original);
    final outputs = <String>[];
    await expectLater(
      setup.apply(
        requested: true,
        originalOutput: 'gpu',
        read: (key) async => values[key.replaceFirst('options/', '')]!,
        write: (key, value) async {
          if (key != 'tone-mapping-param') values[key] = value;
        },
        output: (value) async => outputs.add(value),
      ),
      throwsStateError,
    );
    expect(outputs, isNot(contains('gpu-next')));
    expect(values, original);
    expect(setup.enabled, isFalse);
  });
  test('regression082 native decimal formatting is equivalent', () async {
    final setup = DolbyOutputSetup(), values = Map.of(original);
    await setup.apply(
      requested: true,
      originalOutput: 'gpu',
      read: (key) async => values[key.replaceFirst('options/', '')]!,
      write: (key, value) async {
        values[key] = key == 'tone-mapping-param' && value == '0.5'
            ? '0.500000'
            : value;
      },
      output: (_) async {},
    );
    expect(setup.enabled, isTrue);
    expect(values['tone-mapping-param'], '0.500000');
  });
}
