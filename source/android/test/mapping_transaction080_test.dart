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
  const target = {
    'target-prim': 'bt.709',
    'target-trc': 'bt.1886',
    'tone-mapping': 'bt.2390',
    'tone-mapping-param': '0.5',
    'dither': 'fruit',
    'dither-depth': '8',
    'hdr-compute-peak': 'auto',
  };

  for (final verifyFirstFrame in [true, false]) {
    test(
      'regression080 Dolby ${verifyFirstFrame ? 'target is ready before VO' : 'restores previous color settings'}',
      () async {
        final options = Map<String, String>.from(original);
        final setup = DolbyOutputSetup();
        var selected = 'gpu';
        Future<void> apply(bool enabled) async {
          await setup.apply(
            requested: enabled,
            originalOutput: 'gpu',
            // Both complete delivered/current implementations can use this
            // same native-property substitute. No prefix-only failure is
            // counted as the old implementation's regression.
            read: (key) async => options[key.replaceFirst('options/', '')]!,
            write: (key, value) async {
              options[key] = value;
            },
            output: (value) async {
              if (verifyFirstFrame && value == 'gpu-next') {
                for (final entry in target.entries) {
                  expect(
                    options[entry.key],
                    entry.value,
                    reason: '${entry.key} must be configured before output',
                  );
                }
              }
              selected = value;
            },
          );
        }

        await apply(true);
        if (verifyFirstFrame) {
          expect(selected, 'gpu-next');
        } else {
          // The old application writes these values after the first frame.
          // This checks restoration of that same late configuration too.
          options.addAll(target);
          await apply(false);
          expect(options, original);
          expect(selected, 'gpu');
        }
      },
    );
  }
}
