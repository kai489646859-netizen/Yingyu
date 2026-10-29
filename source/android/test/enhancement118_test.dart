import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/enhancement_output.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';

void main() {
  test(
    'only actual Dolby5/7 on gpu-next opts in, ordinary HDR and Dolby8 stay unchanged',
    () {
      for (final profile in ['', '0', '5', '7', '8', 'unknown']) {
        for (final vo in ['gpu', 'gpu-next', 'unknown']) {
          expect(
            useDolbyEnhancement({'dolby-vision-profile': profile}, vo),
            const {'5', '7'}.contains(profile) && vo == 'gpu-next',
          );
        }
      }
      expect(
        useDolbyEnhancement({'video-params/gamma': 'pq'}, 'gpu-next'),
        false,
      );
    },
  );
  test('all315 ordinary shader bodies retain their verified117 hashes', () {
    final lock =
        jsonDecode(
              File(
                'dependencies/output116/pointwise-sha256.json',
              ).readAsStringSync(),
            )
            as Map;
    final bodies = lock['bodies'] as Map;
    var checked = 0;
    for (final transfer in ShadowTransfer.values) {
      for (final strength in [0.0, .25, .5, .75]) {
        for (var picture = 0; picture <= 15; picture++) {
          if (strength == 0 && picture == 0) continue;
          final name =
              '${transfer.name}-${(strength * 100).round()}-$picture.hook';
          final content = shadowShader(
            transfer,
            strength,
            picture: picture.toDouble(),
          );
          final body = content.split('\n').skip(3).join('\n');
          expect(
            sha256.convert(utf8.encode(body)).toString(),
            bodies[name],
            reason: name,
          );
          checked++;
        }
      }
    }
    expect(checked, 315);
  });
  test(
    'Dolby brightness and shadow require the exact output hash, including paused redraw',
    () async {
      final io = <String, String>{
        'glsl-shaders': '',
        'current-vo': 'gpu-next',
        'options/target-trc': 'bt.1886',
        'video-out-params/gamma': 'pq',
      };
      String? generated;
      String store(String content) {
        generated = content;
        return '/private/${sha256.convert(utf8.encode(content))}.hook';
      }

      final enhancement = ShadowEnhancement();
      Future<void> confirm(String path) => confirmDolbyEnhancement(
        path: path,
        active: () => true,
        renderFailed: () => false,
        read: (_) async => jsonEncode({
          'frame': 1,
          'valid': true,
          'shader': path.isEmpty ? '' : path.split('/').last.substring(0, 64),
        }),
      );
      Future<double> set(double shadow, double picture, bool dolby) =>
          enhancement.set(
            shadow,
            pictureBrightness: picture,
            read: (key) async => io[key]!,
            write: (key, value) async {
              io[key] = value;
            },
            active: () => true,
            store: (content) async => store(content),
            dolbyInplace: dolby,
            confirm: dolby ? confirm : null,
          );
      await set(.75, 0, true);
      expect(enhancement.value, .75);
      expect(generated, contains('//!DESC Yingyu Dolby enhancement v1'));
      await set(.75, 15, true);
      expect(enhancement.picture, 15);
      await set(0, 0, true);
      expect(io['glsl-shaders'], '');
      await set(.75, 15, false);
      expect(generated, shadowShader(ShadowTransfer.bt1886, .75, picture: 15));
    },
  );
  test(
    'accepted option without a rendered enhancement rolls back instead of reporting success',
    () async {
      for (final nativeError in [false, true]) {
        final io = <String, String>{
          'glsl-shaders': '',
          'current-vo': 'gpu-next',
          'options/target-trc': 'bt.1886',
          'video-out-params/gamma': 'pq',
        };
        final enhancement = ShadowEnhancement();
        await expectLater(
          enhancement.set(
            .75,
            pictureBrightness: 15,
            read: (key) async => io[key]!,
            write: (key, value) async {
              io[key] = value;
            },
            active: () => true,
            store: (content) async =>
                '/private/${sha256.convert(utf8.encode(content))}.hook',
            dolbyInplace: true,
            confirm: (path) => confirmDolbyEnhancement(
              path: path,
              read: (_) async => '{"fresh":[{"desc":"old unchanged output"}]}',
              active: () => true,
              renderFailed: () => nativeError,
              timeout: const Duration(milliseconds: 20),
            ),
          ),
          throwsA(isA<AppFailure>()),
        );
        expect(io['glsl-shaders'], '');
        expect(enhancement.value, 0);
        expect(enhancement.picture, 0);
      }
    },
  );
  test(
    'old output description cannot confirm another shader and retired owners stop polling',
    () async {
      var reads = 0;
      await expectLater(
        confirmDolbyEnhancement(
          path: '/private/${'a' * 64}.hook',
          read: (_) async {
            reads++;
            return '{}';
          },
          active: () => false,
          renderFailed: () => false,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(reads, 0);
      expect(
        enhancementRenderError(
          'vo/gpu-next/libplacebo',
          'error',
          'Failed creating render pass',
        ),
        true,
      );
      expect(enhancementRenderError('vd', 'error', 'shader'), false);
      expect(enhancementRenderError('vo/gpu-next', 'warn', 'shader'), false);
    },
  );
}
