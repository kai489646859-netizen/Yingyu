import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/enhancement_output.dart';

void main() {
  test(
    'one slower native reply confirms the rendered shader without overlapping requests',
    () async {
      var reads = 0;
      await confirmDolbyEnhancement(
        path: '/private/${'a' * 64}.hook',
        active: () => true,
        renderFailed: () => false,
        timeout: const Duration(milliseconds: 650),
        read: (_) async {
          reads++;
          await Future<void>.delayed(const Duration(milliseconds: 240));
          return '{"frame":1,"valid":true,"shader":"${'a' * 64}"}';
        },
      );
      expect(reads, 1);
    },
  );
}
