import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'package:yingyu/playback/network_route.dart';
import 'package:yingyu/playback/network_recovery.dart';

void route(
  PlaybackNetworkRoutes state,
  int id, {
  bool online = true,
  String kind = 'wifi',
}) => state.update({'route': id, 'available': online, 'kind': kind});

void main() {
  test('Wi-Fi to Wi-Fi changes generation; duplicate capabilities do not', () {
    final state = PlaybackNetworkRoutes();
    route(state, 1);
    expect(state.revision, 0);
    route(state, 1);
    expect(state.revision, 0);
    route(state, 2);
    expect(state.revision, 1);
    route(state, 2, kind: 'mobile');
    expect(state.kind, 'mobile');
    expect(state.revision, 1);
    route(state, 2, online: false);
    expect(state.revision, 2);
    route(state, 3);
    expect(state.revision, 3);
  });

  for (final variant in [
    'wifi',
    'mobile',
    'offline',
    'identity',
    'cancel',
    'healthy',
  ]) {
    test('exact byte reader handoff $variant', () async {
      final state = PlaybackNetworkRoutes();
      route(state, 1);
      final stalled = StreamController<List<int>>();
      final starts = <int>[];
      final started = Completer<void>();
      final cancellation = DiscReadCancellation();
      final reader = DiscStreamReader(
        (path, start, cancel) async {
          starts.add(start);
          final first = starts.length == 1;
          final tag = !first && variant == 'identity' ? '"changed"' : '"same"';
          if (first) {
            stalled.add([0, 1]);
            started.complete();
          }
          return DiscStreamSource(
            start: start,
            total: 8,
            canResume: true,
            validator: tag,
            identity: DiscStreamIdentity(
              'https://synthetic.invalid/direct',
              tag,
              8,
            ),
            bytes: first
                ? stalled.stream
                : Stream.value(List.generate(8 - start, (i) => i + start)),
            close: (_) {
              if (first) unawaited(stalled.close());
            },
          );
        },
        network: state,
        networkGrace: const Duration(milliseconds: 15),
      );
      try {
        final result = reader.read('', 0, 8, cancellation);
        final failed = variant == 'identity' || variant == 'cancel';
        final check = failed
            ? expectLater(result, throwsA(isA<Exception>()))
            : expectLater(
                result.then((v) => v.bytes),
                completion([0, 1, 2, 3, 4, 5, 6, 7]),
              );
        await started.future;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (variant == 'offline') {
          route(state, 2, online: false);
          stalled.addError(const NetworkHandoff());
          await Future<void>.delayed(const Duration(milliseconds: 5));
          expect(starts, [0]);
        }
        route(state, 3, kind: variant == 'mobile' ? 'mobile' : 'wifi');
        if (variant == 'cancel') cancellation.cancel();
        if (variant == 'healthy') {
          stalled.add([2, 3, 4, 5, 6, 7]);
        }
        await check;
        expect(
          starts,
          variant == 'healthy' || variant == 'cancel' ? [0] : [0, 2],
        );
      } finally {
        await reader.close();
      }
    });
  }

  for (final action in [
    'recover',
    'healthy',
    'pause',
    'seek',
    'close',
    'offline',
  ]) {
    test('native recovery controller $action', () async {
      var eligible = action != 'healthy', attempts = 0;
      final recovery = NetworkPlaybackRecovery(
        eligible: () => eligible,
        recover: (current) async {
          if (current()) attempts++;
        },
        onError: (error) => fail('$error'),
        tick: const Duration(milliseconds: 5),
      );
      recovery.changed(action != 'offline');
      if (action == 'pause') eligible = false;
      if (action == 'seek') recovery.cancel();
      if (action == 'close') recovery.close();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(attempts, action == 'recover' ? 1 : 0);
      recovery.close();
    });
  }
  test(
    'rapid network changes collapse; at most three native recoveries',
    () async {
      var attempts = 0;
      final recovery = NetworkPlaybackRecovery(
        eligible: () => true,
        recover: (current) async {
          if (current()) attempts++;
        },
        onError: (error) => fail('$error'),
        tick: const Duration(milliseconds: 2),
      );
      for (var i = 0; i < 8; i++) {
        recovery.changed(true);
        recovery.changed(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(attempts, 3);
      recovery.close();
    },
  );
  for (final variant in [
    'success',
    'cancel',
    'seekError',
    'writeError',
    'restoreError',
  ]) {
    test('native cache transaction restores after $variant', () async {
      final values = {'demuxer-seekable-cache': 'auto', 'seeking': 'no'};
      var active = true, seeks = 0;
      final work = freshNetworkSeek(
        read: (key) async => values[key]!,
        write: (key, value) async {
          values[key] = value;
          if (variant == 'cancel' && value == 'no') active = false;
          if (variant == 'writeError' && value == 'no' ||
              variant == 'restoreError' && value == 'auto') {
            throw StateError('injected');
          }
        },
        seek: () async {
          seeks++;
          if (variant == 'seekError') throw StateError('seek');
        },
        restarted: () => seeks > 0,
        active: () => active,
      );
      if (variant.endsWith('Error')) {
        await expectLater(work, throwsA(anything));
      } else {
        await work;
      }
      expect(values['demuxer-seekable-cache'], 'auto');
      if (variant == 'cancel' || variant == 'writeError') expect(seeks, 0);
    });
  }
}
