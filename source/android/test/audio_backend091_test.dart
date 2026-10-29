import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' show AudioTrack;
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/tracks.dart';
import 'host/audio091/old.dart' as old;
import 'host/audio091/new.dart' as current;

const target = TrackOption('2', '音轨2', AudioTrack('2', null, null));
void main() {
  test(
    'complete error handler delegates eight faults to bounded switch only',
    () {
      final before = old.Harness()..hold(true);
      final after = current.Harness()..hold(true);
      for (var i = 0; i < 8; i++) {
        before.packetError();
        after.packetError();
      }
      expect(before.failure, isNotNull);
      expect(after.failure, null);
      expect(after.errors, 8);
      after.hold(false);
      after.packetError();
      expect(after.failure, isNotNull);
    },
  );
  test(
    'complete error handler scopes audio initialization rejection without hiding terminal errors',
    () {
      final before = old.Harness()..hold(true);
      final after = current.Harness()..hold(true);
      before.reject();
      after.reject();
      expect(before.failure, isNotNull);
      expect(after.failure, null);
      expect(after.rejected, true);
      after.hold(false);
      after.reject();
      expect(after.failure, isNotNull);
    },
  );
  test(
    'complete delivered method accepts ID even though new track has no output',
    () async {
      final before = old.Harness();
      before.player.platform.bad = true;
      await before.audio(target);
      expect(before.player.platform.aid, '2');
      expect(before.seeks, isEmpty);
      await expectLater(
        before.player.platform.getProperty('audio-pts'),
        throwsStateError,
      );
      final after = current.Harness();
      after.player.platform.bad = true;
      await expectLater(after.audio(target), throwsA(isA<AppFailure>()));
      expect(after.player.platform.aid, '1');
      expect(after.player.selected, ['2', '1']);
      expect(after.seeks.length, 2);
      expect(after.failure, null);
      expect(after.held, false);
    },
  );
  test(
    'complete new disc method primes requested track and releases guard',
    () async {
      final after = current.Harness();
      await after.audio(target);
      expect(after.player.platform.aid, '2');
      expect(after.seeks.length, 1);
      expect(after.held, false);
      expect(after.player.state.playing, true);
      expect(after.failure, null);
    },
  );
  test('complete new paused method preserves paused state', () async {
    final after = current.Harness();
    after.player.state.playing = false;
    await after.audio(target);
    expect(after.player.state.playing, false);
    expect(after.seeks.length, 1);
    expect(after.held, false);
  });
  test(
    'complete new method cancels late proof after exit without rollback',
    () async {
      final after = current.Harness();
      final result = after.audio(target);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      after.exit();
      await expectLater(result, throwsA(isA<AppFailure>()));
      expect(after.player.selected, ['2']);
      expect(after.held, false);
    },
  );
}
