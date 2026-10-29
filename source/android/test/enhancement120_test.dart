import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/enhancement_output.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';

class ProofIo120 {
  final values = <String, String>{
    'glsl-shaders': '',
    'current-vo': 'gpu-next',
    'options/target-trc': 'bt.1886',
    'video-out-params/gamma': 'pq',
  };
  final gain = ShadowEnhancement();
  int frame = 0, fault = 0, writes = 0;
  String displayed = '';
  bool active = true, render = true;
  Future<String> read(String key) async {
    if (key == 'yingyu-enhancement-state') {
      return jsonEncode({'frame': frame, 'valid': true, 'shader': displayed});
    }
    return values[key]!;
  }

  Future<double> set(double shadow, double picture) {
    final check = DolbyEnhancementConfirmation(
      read: read,
      active: () => active,
      renderFault: () => fault,
      timeout: const Duration(milliseconds: 75),
    );
    return gain.set(
      shadow,
      pictureBrightness: picture,
      read: read,
      write: (key, value) async {
        writes++;
        values[key] = value;
        if (render) {
          frame++;
          displayed = value.isEmpty
              ? ''
              : value.split('/').last.substring(0, 64);
        }
      },
      active: () => active,
      dolbyInplace: true,
      store: (content) async =>
          '/private/${sha256.convert(utf8.encode(content))}.hook',
      prepareConfirmation: check.prepare,
      confirm: check.confirm,
    );
  }
}

void main() {
  test(
    'cancelled baseline read stops the transaction before native writes',
    () async {
      var active = true;
      final confirmation = DolbyEnhancementConfirmation(
        read: (_) async {
          active = false;
          return '{"frame":1,"valid":true,"shader":""}';
        },
        active: () => active,
        renderFault: () => 0,
      );
      await expectLater(confirmation.prepare(), throwsA(isA<AppFailure>()));
    },
  );
  for (final cancellation in [true, false]) {
    test(
      'reply cannot confirm after ${cancellation ? 'session cancellation' : 'a render fault'}',
      () async {
        var active = true, fault = false;
        var reads = 0;
        await expectLater(
          confirmDolbyEnhancement(
            path: '/private/${'a' * 64}.hook',
            afterFrame: 1,
            active: () => active,
            renderFailed: () => fault,
            read: (_) async {
              reads++;
              if (cancellation) {
                active = false;
              } else {
                fault = true;
              }
              return jsonEncode({
                'frame': 2,
                'valid': true,
                'shader': 'a' * 64,
              });
            },
          ),
          throwsA(isA<AppFailure>()),
        );
        expect(reads, 1);
      },
    );
  }
  test(
    'historical descriptions and the same old full hash cannot confirm a new frame',
    () async {
      final hash = 'a' * 64;
      await expectLater(
        confirmDolbyEnhancement(
          path: '/private/$hash.hook',
          afterFrame: 4,
          active: () => true,
          renderFailed: () => false,
          timeout: const Duration(milliseconds: 60),
          read: (_) async => jsonEncode({
            'frame': 4,
            'valid': true,
            'shader': hash,
            'fresh': [
              {'desc': 'Yingyu Dolby gain ${hash.substring(0, 12)}'},
            ],
          }),
        ),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  for (final kind in ['picture', 'shadow']) {
    test(
      '$kind A-B-A requires this update; rejected update preserves B',
      () async {
        final h = ProofIo120();
        Future<double> set(double value) async {
          return h.set(
            kind == 'shadow' ? value : 0,
            kind == 'picture' ? value : 0,
          );
        }

        final a = kind == 'picture' ? 5.0 : .25,
            b = kind == 'picture' ? 10.0 : .75;
        await set(a);
        await set(b);
        final before = h.displayed;
        h.render = false;
        await expectLater(set(a), throwsA(isA<AppFailure>()));
        expect(h.displayed, before);
        expect(kind == 'picture' ? h.gain.picture : h.gain.value, b);
        h.render = true;
        await set(a);
        expect(kind == 'picture' ? h.gain.picture : h.gain.value, a);
      },
    );
  }
  test('off requires a new submitted original frame', () async {
    await expectLater(
      confirmDolbyEnhancement(
        path: '',
        afterFrame: 9,
        active: () => true,
        renderFailed: () => false,
        timeout: const Duration(milliseconds: 60),
        read: (_) async => '{"frame":9,"valid":true,"shader":""}',
      ),
      throwsA(isA<AppFailure>()),
    );
    await confirmDolbyEnhancement(
      path: '',
      afterFrame: 9,
      active: () => true,
      renderFailed: () => false,
      read: (_) async => '{"frame":10,"valid":true,"shader":""}',
    );
  });
  test(
    'a newer wrong hash, failed submission and malformed evidence never confirm',
    () async {
      for (final raw in [
        jsonEncode({'frame': 2, 'valid': true, 'shader': 'b' * 64}),
        jsonEncode({'frame': 2, 'valid': false, 'shader': 'a' * 64}),
        '{"frame":2.5,"valid":true,"shader":""}',
        '{"frame":-1,"valid":true,"shader":""}',
        '{"frame":2,"valid":"yes","shader":""}',
        'x' * 1025,
      ]) {
        await expectLater(
          confirmDolbyEnhancement(
            path: '/private/${'a' * 64}.hook',
            afterFrame: 1,
            active: () => true,
            renderFailed: () => false,
            timeout: const Duration(milliseconds: 45),
            read: (_) async => raw,
          ),
          throwsA(isA<AppFailure>()),
        );
      }
    },
  );
  test(
    'baseline is read before writing and missing baseline cannot write',
    () async {
      var writes = 0;
      final confirmation = DolbyEnhancementConfirmation(
        read: (_) async => '{}',
        active: () => true,
        renderFault: () => 0,
      );
      await expectLater(
        ShadowEnhancement().set(
          .25,
          read: (key) async => key == 'current-vo'
              ? 'gpu-next'
              : key == 'options/target-trc'
              ? 'bt.1886'
              : key == 'video-out-params/gamma'
              ? 'pq'
              : '',
          write: (_, _) async {
            writes++;
          },
          active: () => true,
          store: (_) async => '/private/${'a' * 64}.hook',
          prepareConfirmation: confirmation.prepare,
          confirm: confirmation.confirm,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(writes, 0);
    },
  );
  test(
    'rollback takes a new baseline and confirms the restored submitted frame',
    () async {
      final h = ProofIo120();
      final check = DolbyEnhancementConfirmation(
        read: h.read,
        active: () => h.active,
        renderFault: () => h.fault,
      );
      var confirmations = 0, preparations = 0;
      await expectLater(
        h.gain.set(
          .5,
          read: h.read,
          active: () => true,
          dolbyInplace: true,
          store: (content) async =>
              '/private/${sha256.convert(utf8.encode(content))}.hook',
          write: (key, value) async {
            h.values[key] = value;
            h.frame++;
            h.displayed = value.isEmpty
                ? ''
                : value.split('/').last.substring(0, 64);
          },
          prepareConfirmation: () async {
            preparations++;
            await check.prepare();
          },
          confirm: (path) async {
            confirmations++;
            if (confirmations == 1) {
              h.fault++;
              throw const AppFailure('synthetic render fault');
            }
            await check.confirm(path);
          },
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(preparations, 2);
      expect(confirmations, 2);
      expect(h.gain.value, 0);
      expect(h.values['glsl-shaders'], '');
      expect(h.displayed, '');
    },
  );
}
