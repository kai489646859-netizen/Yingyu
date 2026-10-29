import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';
import 'host/enhancement118/backend.dart';

void main() {
  test(
    'selected P7 SDR uses stronger monotone gains, P5 stays exact',
    () async {
      for (final profile in ['5', '7', '8', '0']) {
        final h = EnhancementBackend()..profile(profile);
        await h.setPictureBrightness(15, allowed: () => true);
        await h.setShadowEnhancement(.75, allowed: () => true);
        final plain = shadowShader(ShadowTransfer.bt1886, .75, picture: 15);
        if (profile == '7') {
          expect(h.generated, contains('(1.0 + 1.500000) /'));
          expect(h.generated, contains('(1.0 + 4.80) /'));
        } else {
          expect(
            h.generated,
            profile == '5'
                ? plain.replaceFirst(
                    RegExp(r'//!DESC [^\n]+'),
                    '//!DESC Yingyu Dolby enhancement v1',
                  )
                : plain,
          );
        }
        await h.setShadowEnhancement(0, allowed: () => true);
        await h.setPictureBrightness(0, allowed: () => true);
        expect(h.io.values['glsl-shaders'], '');
      }
    },
  );

  test('HDR P7 output keeps its original transfer and curve', () async {
    for (final target in ['pq', 'hlg']) {
      final h = EnhancementBackend()..profile('7');
      h.io.values['options/target-trc'] = target;
      await h.setPictureBrightness(15, allowed: () => true);
      expect(h.generated, isNot(contains('(1.0 + 1.500000) /')));
    }
  });

  test(
    'all P7 SDR bodies match native admission and optional GPU fixtures',
    () {
      final output = Platform.environment['YINGYU_P7_FIXTURES'];
      final hashes = <String, String>{};
      for (final transfer in [
        ShadowTransfer.bt1886,
        ShadowTransfer.gamma22,
        ShadowTransfer.srgb,
      ]) {
        for (final strength in [0.0, .25, .5, .75]) {
          for (var picture = 0; picture <= 15; picture++) {
            if (strength == 0 && picture == 0) continue;
            final name =
                '${transfer.name}-${(strength * 100).round()}-$picture.hook';
            final content = shadowShader(
              transfer,
              strength,
              picture: picture.toDouble(),
              p7Sdr: true,
            );
            hashes[name] = sha256
                .convert(utf8.encode(content.split('\n').skip(3).join('\n')))
                .toString();
            if (output != null) {
              final file = File('$output/$name');
              file.parent.createSync(recursive: true);
              file.writeAsStringSync(content);
            }
          }
        }
      }
      expect(hashes.length, 189);
      if (output != null) {
        File('$output/manifest.json').writeAsStringSync(jsonEncode(hashes));
      } else {
        expect(
          hashes,
          jsonDecode(
            File(
              'dependencies/enhancement123/p7-sha256.json',
            ).readAsStringSync(),
          ),
        );
      }
    },
  );
}
