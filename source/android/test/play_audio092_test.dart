import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/audio_refresh.dart';
import 'package:yingyu/playback/audio_track_switch.dart';
import 'host/intent092/old.dart' as old;
import 'host/intent092/new.dart' as current;

void main() {
  test(
    'complete 091 replay cancels requested play on automatic audio seek; current preserves it',
    () async {
      final before = old.Harness(), after = current.Harness();
      for (final h in <dynamic>[before, after]) {
        final entered = Completer<void>(), ready = Completer<void>();
        h.native.beforeRead = (String key) async {
          if (key == 'demuxer-cache-duration') {
            if (!entered.isCompleted) entered.complete();
            await ready.future;
          }
        };
        final playing = h.play() as Future<void>;
        await entered.future;
        await h.internalSeek(const Duration(seconds: 2698));
        ready.complete();
        await playing;
      }
      expect(before.player.playCalls, 0);
      expect(after.player.playCalls, 1);
      expect(after.player.state.playing, true);
    },
  );
  for (final action in ['pause', 'seek', 'exit']) {
    test(
      'complete play still respects explicit $action during internal audio seek',
      () async {
        final h = current.Harness();
        final entered = Completer<void>(), ready = Completer<void>();
        h.native.beforeRead = (String key) async {
          if (key == 'demuxer-cache-duration') {
            if (!entered.isCompleted) entered.complete();
            await ready.future;
          }
        };
        final playing = h.play();
        await entered.future;
        await h.internalSeek(const Duration(seconds: 50));
        if (action == 'pause') await h.pause();
        if (action == 'seek') await h.seek(const Duration(seconds: 80));
        if (action == 'exit') h.close();
        ready.complete();
        await playing;
        expect(h.player.playCalls, 0);
      },
    );
  }
  test(
    'complete fresh seek bypasses cached packets, retains target and restores options',
    () async {
      final h = current.Harness();
      var sourceRead = false;
      h.player.beforeSeek = (Duration target) async {
        expect(target, const Duration(seconds: 2684));
        sourceRead = h.native.values['demuxer-seekable-cache'] == 'no';
        expect(double.parse(h.native.values['hr-seek-demuxer-offset']!), 1);
        h.restarted();
      };
      await h.freshSeek(const Duration(seconds: 2684));
      expect(sourceRead, true);
      expect(h.native.values['demuxer-seekable-cache'], 'auto');
      expect(h.native.values['hr-seek-demuxer-offset'], '0.000000');
      expect(h.player.playCalls, 0);
      expect(h.player.pauseCalls, 0);
    },
  );
  test(
    'old seeking=no cannot acknowledge fresh seek before actual restart',
    () async {
      final h = current.Harness();
      final issued = Completer<void>();
      h.player.beforeSeek = (_) async => issued.complete();
      var finished = false;
      final pending = h
          .freshSeek(const Duration(seconds: 40))
          .then((_) => finished = true);
      await issued.future;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(finished, false);
      expect(h.native.values['demuxer-seekable-cache'], 'no');
      h.restarted();
      await pending;
      expect(h.native.values['demuxer-seekable-cache'], 'auto');
    },
  );
  test(
    'new user seek cancels refresh and runs only after option restoration',
    () async {
      final h = current.Harness();
      final issued = Completer<void>();
      h.player.beforeSeek = (Duration target) async {
        if (target.inSeconds == 40) {
          issued.complete();
        } else {
          expect(h.native.values['demuxer-seekable-cache'], 'auto');
          expect(h.native.values['hr-seek-demuxer-offset'], '0.000000');
        }
      };
      final pending = h.freshSeek(const Duration(seconds: 40));
      await issued.future;
      await h.seek(const Duration(seconds: 80));
      await pending;
      expect(h.player.seeks, [
        const Duration(seconds: 40),
        const Duration(seconds: 80),
      ]);
    },
  );
  for (final mode in ['cancel', 'seek failure', 'timeout', 'write failure']) {
    test('fresh seek restores options after $mode', () async {
      final values = <String, String>{
        'demuxer-seekable-cache': 'yes',
        'hr-seek-demuxer-offset': '2.000000',
        'seeking': 'no',
      };
      var active = true, seeks = 0, writes = 0;
      final job = freshAudioSeek(
        read: (key) async => values[key]!,
        write: (key, value) async {
          writes++;
          values[key] = value;
          if (mode == 'write failure' && writes == 1) {
            throw StateError('rejected');
          }
        },
        seek: () async {
          seeks++;
          if (mode == 'seek failure') throw StateError('seek failed');
          if (mode == 'cancel') active = false;
        },
        restarted: () => false,
        active: () => active,
        timeout: const Duration(milliseconds: 40),
      );
      if (mode == 'cancel') {
        await job;
      } else {
        await expectLater(job, throwsStateError);
      }
      expect(values['demuxer-seekable-cache'], 'yes');
      expect(values['hr-seek-demuxer-offset'], '2.000000');
      expect(seeks, mode == 'write failure' ? 0 : 1);
    });
  }
  test(
    'restoration tries every option and preserves real restoration failure',
    () async {
      final values = <String, String>{
        'demuxer-seekable-cache': 'auto',
        'hr-seek-demuxer-offset': '0.000000',
        'seeking': 'no',
      };
      final restores = <String>[];
      await expectLater(
        freshAudioSeek(
          read: (key) async => values[key]!,
          write: (key, value) async {
            if (value == '0.000000' || value == 'auto') restores.add(key);
            if (value == '0.000000') throw StateError('restore rejected');
            values[key] = value;
          },
          seek: () async {},
          restarted: () => true,
          active: () => true,
        ),
        throwsA(isA<AudioRefreshRestoreFailure>()),
      );
      expect(restores, ['hr-seek-demuxer-offset', 'demuxer-seekable-cache']);
    },
  );
  test(
    'fatal option restoration failure is never retried as ordinary track failure',
    () async {
      var aid = '1', selections = 0;
      await expectLater(
        switchAudioTrack(
          requested: '2',
          disc: true,
          read: (_) async => aid,
          select: (id) async {
            aid = id;
            selections++;
          },
          refresh: () async => throw const AudioRefreshRestoreFailure(),
          active: () => true,
          playing: () => true,
          packetErrors: () => 0,
        ),
        throwsA(isA<AudioRefreshRestoreFailure>()),
      );
      expect(selections, 1);
    },
  );
  test('ordinary complete internal seek retains original seek path', () async {
    final h = current.Harness()..ordinary();
    await h.internalSeek(const Duration(seconds: 30));
    expect(h.player.seeks, [const Duration(seconds: 30)]);
    expect(
      h.native.commands.where((s) => s.contains('demuxer-seekable-cache')),
      isEmpty,
    );
    expect(h.player.playCalls, 0);
  });
  test(
    'complete queued seek cannot use options after a failed restoration',
    () async {
      final h = current.Harness();
      h.player.beforeSeek = (_) async => h.restarted();
      h.native.beforeWrite = (key, value) async {
        if (key == 'hr-seek-demuxer-offset' && value == '0.000000') {
          throw StateError('restore failed');
        }
      };
      await expectLater(
        h.freshSeek(const Duration(seconds: 40)),
        throwsA(isA<AudioRefreshRestoreFailure>()),
      );
      expect(h.failure, isNotNull);
      await expectLater(
        h.seek(const Duration(seconds: 80)),
        throwsA(isA<current.AppFailure>()),
      );
      expect(h.player.seeks, [const Duration(seconds: 40)]);
      expect(h.native.values['demuxer-seekable-cache'], 'auto');
    },
  );
}
