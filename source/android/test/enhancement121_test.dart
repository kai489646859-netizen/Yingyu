import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/enhancement_output.dart';

void main() {
  for (final message in [
    'User hook tried resizing non-resizable stage!',
    'Failed executing hook, disabling',
  ]) {
    test(
      'current renderer hook rejection is an enhancement fault: $message',
      () {
        expect(
          enhancementRenderError('vo/gpu-next/libplacebo', 'error', message),
          true,
        );
        expect(enhancementRenderError('vd', 'error', message), false);
        expect(enhancementRenderError('vo/gpu-next', 'warn', message), false);
      },
    );
  }
}
