import 'package:flutter_test/flutter_test.dart';
import 'host/network211_backend.dart';

void main() {
  for (final cause in [
    'none',
    'load',
    'pause',
    'seek',
    'dispose',
    'repair',
    'track',
  ]) {
    test(
      'native recovery admission rechecks $cause after async seekability',
      () async {
        final backend = NetworkBackendHarness();
        final job = backend.recoverNetwork(() => true);
        if (cause != 'none') backend.invalidate(cause);
        backend.player.native.gate.complete();
        await job;
        expect(backend.seeks, cause == 'none' ? 1 : 0);
        if (cause == 'none') {
          expect(backend.target, const Duration(seconds: 50));
          expect(backend.refresh, isTrue);
        }
      },
    );
  }
  for (final cause in ['disc', 'cached', 'live', 'inactive']) {
    test('native recovery leaves $cause path alone', () async {
      final backend = NetworkBackendHarness();
      backend.invalidate(cause);
      if (cause == 'live') backend.player.native.seekable = 'no';
      backend.player.native.gate.complete();
      await backend.recoverNetwork(() => cause != 'inactive');
      expect(backend.seeks, 0);
    });
  }
}
