import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/dolby_source.dart';

// Uses only the public function already present in the complete 0.8.0 source.
// The same test can be replayed against that source without a missing-new-API
// compilation failure masquerading as a regression.
void main() {
  test(
    'regression081 generic mapper failure is not proof of an unsafe pair',
    () {
      expect(
        isDolbyOutputFailure(
          'vo/gpu-next',
          'error',
          'Mapping hardware decoded surface failed.',
        ),
        isFalse,
        reason:
            'A flushed/released buffer also reaches this generic message; '
            'the backend must classify it and allow only bounded seek recovery.',
      );
    },
  );

  test(
    'regression081 confirmed pairing and capability failures remain fatal',
    () {
      for (final message in [
        'Dolby surface timestamp does not match codec output',
        'Timed out matching a Dolby surface to its metadata',
        'Raw external YUV sampling is unavailable',
      ]) {
        expect(
          isDolbyOutputFailure('vo/gpu-next/aimagereader', 'error', message),
          isTrue,
        );
      }
    },
  );
}
