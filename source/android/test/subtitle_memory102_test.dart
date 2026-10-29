import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/subtitle_position_memory.dart';
import 'core_test.dart' show syntheticSession, response, playbackData;
import 'subtitle_position088_test.dart' show PositionBackend;
import 'dart:convert';
import 'host/subtitle102/old_session.dart' as old;

class RememberedBackend extends PositionBackend
    implements InitialSubtitlePositionBackend, DefaultSubtitlePositionBackend {
  double? initialPosition;
  bool configured = false, automatic = true, reject = false;
  Completer<void>? pending;
  @override
  bool get usesDefaultSubtitlePosition => automatic;
  @override
  void configureSubtitlePosition(double? value) {
    configured = true;
    initialPosition = value;
    automatic = value == null;
  }

  @override
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  }) async {
    await pending?.future;
    if (reject || !allowed()) {
      throw const AppFailure('Synthetic position rejection');
    }
    automatic = false;
    return super.setSubtitlePosition(value, allowed: allowed);
  }

  @override
  Future<double> resetSubtitlePosition({
    required bool Function() allowed,
  }) async {
    if (reject || !allowed()) {
      throw const AppFailure('Synthetic reset rejection');
    }
    automatic = true;
    return 25; // Displayed automatic geometry, not a manual preference.
  }
}

class ScopedRememberedBackend extends RememberedBackend
    implements ScopedSubtitlePositionBackend {
  SubtitlePositionScope scope = SubtitlePositionScope.regular;
  double? discInitial;
  @override
  SubtitlePositionScope get subtitlePositionScope => scope;
  @override
  void configureDiscSubtitlePosition(double? value) {
    discInitial = value;
  }
}

void main() {
  late AppStore store;
  late EmbyClient api;
  final sessions = <PlaybackSession>[];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    api = EmbyClient(
      client: MockClient(
        (r) async => r.url.path.endsWith('PlaybackInfo')
            ? response(jsonEncode(playbackData()), 200)
            : r.url.path.contains('Sessions/Playing')
            ? response('', 204)
            : response('{"Id":"movie","Type":"Movie"}', 200),
      ),
    )..session = syntheticSession();
  });
  tearDown(() async {
    for (final session in sessions) {
      session.ready = false;
      await session.close();
    }
    sessions.clear();
    api.close();
    store.log.dispose();
    store.dispose();
  });
  PlaybackSession create(
    RememberedBackend backend, {
    bool phone = false,
    bool ready = true,
  }) {
    final s = PlaybackSession(
      api: api,
      store: store,
      item: MediaItem({'Id': 'movie'}),
      backend: backend,
    );
    s.configureSubtitleViewport(phone: phone);
    s.loading = false;
    s.ready = ready;
    sessions.add(s);
    return s;
  }

  double? remembered({
    SubtitlePositionScope scope = SubtitlePositionScope.regular,
  }) => store.subtitlePositions.read(
    SubtitleViewport.tablet,
    scope: scope,
    resource: SubtitlePositionTarget.resolve(
      api.session!,
      MediaItem({'Id': 'movie'}),
    )!.key,
  );

  for (final phone in [true, false]) {
    test(
      'ISO bitmap position and manual screen bottom are restored before playback on ${phone ? 'phone' : 'tablet'}',
      () async {
        final first = create(RememberedBackend(), phone: phone);
        await first.setSubtitlePosition(45);
        final nextBackend = RememberedBackend();
        final next = create(nextBackend, phone: phone);
        expect(nextBackend.configured, true);
        expect(nextBackend.initialPosition, 45);
        expect(nextBackend.automatic, false);
        await next.setSubtitlePosition(0);
        final last = RememberedBackend();
        create(last, phone: phone);
        expect(last.initialPosition, 0);
        expect(last.automatic, false);
      },
    );
  }
  test(
    'reset clears manual memory and preserves automatic geometry for the same resource',
    () async {
      final s = create(RememberedBackend());
      await s.setSubtitlePosition(60);
      expect(await s.resetSubtitlePosition(), 25);
      final next = RememberedBackend();
      create(next);
      expect(next.initialPosition, isNull);
      expect(next.automatic, true);
    },
  );
  test(
    'complete delivered session and current session use the same native write, only current persists it',
    () async {
      final oldBackend = RememberedBackend();
      final before =
          old.PlaybackSession(
              api: api,
              store: store,
              item: MediaItem({'Id': 'movie'}),
              backend: oldBackend,
            )
            ..ready = true
            ..loading = false;
      await before.setSubtitlePosition(40);
      expect(oldBackend.values['sub-pos'], '60.000');
      expect(remembered(), isNull);
      before.ready = false;
      await before.close();
      final afterBackend = RememberedBackend();
      final after = create(afterBackend);
      await after.setSubtitlePosition(40);
      expect(afterBackend.values, oldBackend.values);
      expect(remembered(), 40);
    },
  );
  test('phone and tablet profiles stay separate', () async {
    final p = create(RememberedBackend(), phone: true);
    await p.setSubtitlePosition(30);
    final t = create(RememberedBackend());
    await t.setSubtitlePosition(70);
    final p2 = RememberedBackend(), t2 = RememberedBackend();
    create(p2, phone: true);
    create(t2);
    expect(p2.initialPosition, 30);
    expect(t2.initialPosition, 70);
  });
  test(
    'rejected native writes and rejected resets do not replace the last accepted preference',
    () async {
      final b = RememberedBackend();
      final s = create(b);
      await s.setSubtitlePosition(35);
      b.reject = true;
      await expectLater(s.setSubtitlePosition(80), throwsException);
      await expectLater(s.resetSubtitlePosition(), throwsException);
      expect(remembered(), 35);
    },
  );
  test(
    'retired in-flight position cannot overwrite the next player preference',
    () async {
      final b = RememberedBackend()..pending = Completer<void>();
      final s = create(b);
      final old = s.setSubtitlePosition(80);
      await Future<void>.delayed(Duration.zero);
      final next = create(RememberedBackend());
      await next.setSubtitlePosition(20);
      b.pending!.complete();
      await old;
      expect(remembered(), 20);
    },
  );
  test('ordered adjustments retain the last acknowledged value', () async {
    final b = RememberedBackend()..pending = Completer<void>();
    final s = create(b);
    final a = s.setSubtitlePosition(10), c = s.setSubtitlePosition(75);
    b.pending!.complete();
    await Future.wait([a, c]);
    expect(remembered(), 75);
  });
  for (final phone in [true, false]) {
    test(
      'actual session keeps disc and ordinary positions separate on ${phone ? 'phone' : 'tablet'}',
      () async {
        final b = ScopedRememberedBackend();
        final s = create(b, phone: phone);
        await s.setSubtitlePosition(60);
        b.scope = SubtitlePositionScope.discEmbedded;
        await s.setSubtitlePosition(30);
        final next = ScopedRememberedBackend();
        final again = create(next, phone: phone);
        expect(next.initialPosition, 60);
        expect(next.discInitial, 30);
        next.scope = SubtitlePositionScope.discEmbedded;
        await again.resetSubtitlePosition();
        final last = ScopedRememberedBackend();
        create(last, phone: phone);
        expect(last.initialPosition, 60);
        expect(last.discInitial, isNull);
      },
    );
  }
  test(
    'scope change during a pending adjustment cannot save into either wrong category',
    () async {
      final b = ScopedRememberedBackend()..pending = Completer<void>();
      final s = create(b);
      final job = s.setSubtitlePosition(70);
      await Future<void>.delayed(Duration.zero);
      b.scope = SubtitlePositionScope.discEmbedded;
      b.pending!.complete();
      await expectLater(job, throwsException);
      expect(remembered(), isNull);
      expect(remembered(scope: SubtitlePositionScope.discEmbedded), isNull);
    },
  );
}
