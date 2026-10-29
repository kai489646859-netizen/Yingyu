import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';

void main() {
  test('export every UI enhancement combination without changing its math', () {
    final dir = Directory('build/speed116/shaders')
      ..createSync(recursive: true);
    var count = 0;
    for (final trc in ShadowTransfer.values) {
      for (final shadow in [0.0, .25, .5, .75]) {
        for (var picture = 0; picture <= 15; picture++) {
          if (shadow == 0 && picture == 0) continue;
          final body = shadowShader(trc, shadow, picture: picture.toDouble());
          expect(body.split('HOOKED_tex(HOOKED_pos)').length, 2);
          expect(body, isNot(contains('textureOffset')));
          File(
            '${dir.path}/${trc.name}-${(shadow * 100).round()}-$picture.hook',
          ).writeAsStringSync(body);
          count++;
        }
      }
    }
    expect(count, 315);
  });
}
