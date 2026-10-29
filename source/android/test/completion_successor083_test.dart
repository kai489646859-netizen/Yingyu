// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Inject only synthetic preference failures; no device/account data.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem _item(
  int seconds, {
  bool played = false,
  String? date = '2020-01-01T00:00:00Z',
}) => MediaItem({
  'Id': 'movie',
  'Type': 'Movie',
  'RunTimeTicks': 6000000000,
  'UserData': {
    'PlaybackPositionTicks': ticks(Duration(seconds: seconds)),
    'Played': played,
    'PlayCount': played ? 2 : 1,
    'IsFavorite': false,
    'LastPlayedDate': ?date,
  },
});

class _Fixture {
  _Fixture(this.store) {
    api = EmbyClient(
      client: MockClient((request) async {
        if (request.url.path.contains('/PlayedItems/')) {
          marks++;
          markEntered?.complete();
          await markRelease?.future;
          server = _item(
            0,
            played: true,
            date: request.url.queryParameters['DatePlayed'],
          );
          return response('{}', 200);
        }
        if (request.url.path.endsWith('/Resume')) {
          return response(
            jsonEncode({
              'Items': [if (server.resume > Duration.zero) server.data],
            }),
            200,
          );
        }
        final captured = server;
        reads++;
        if (reads == 1 && readEntered != null) {
          readEntered!.complete();
          await readRelease!.future;
        }
        return response(jsonEncode(captured.data), 200);
      }),
    )..session = syntheticSession();
  }
  final AppStore store;
  late final EmbyClient api;
  Session get account => api.session!;
  MediaItem server = _item(120);
  int marks = 0, reads = 0;
  Completer<void>? markEntered, markRelease, readEntered, readRelease;
  Future<void> remember() => store.completions.remember(
    account,
    _item(120),
    const Duration(minutes: 10),
  );
  Future<void> save(
    int seconds, {
    bool completed = false,
    bool Function()? allowed,
  }) => store.saveProgress(
    account,
    'movie',
    Duration(seconds: seconds),
    serverBaseline: _item(120),
    keepZeroDisplay: seconds == 0 && !completed,
    completed: completed,
    allowed: allowed,
  );
  Future<void> acknowledge(int seconds) async {
    await store.observeProgress(account, server, Duration(seconds: seconds));
    await store.confirmProgress(account, 'movie', Duration(seconds: seconds));
  }

  void close() {
    api.close();
    store.log.dispose();
    store.dispose();
  }
}

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences() : super.withData({});
  bool failProtection = false, throwProtection = false, delayProtection = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key.startsWith('flutter.yingyu.completed.') &&
        value is String &&
        value.contains('"superseded":true')) {
      if (throwProtection) throw StateError('synthetic protection write');
      if (failProtection) return false;
      final result = await super.setValue(type, key, value);
      if (delayProtection) {
        entered.complete();
        await release.future;
      }
      return result;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<_Fixture> fixture() async {
    SharedPreferences.setMockInitialValues({});
    final value = _Fixture(AppStore(await SharedPreferences.getInstance()));
    addTearDown(value.close);
    return value;
  }

  Future<(_Fixture, _Preferences)> controlled() async {
    SharedPreferences.setMockInitialValues({});
    final platform = _Preferences();
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = platform;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    final value = _Fixture(AppStore(await SharedPreferences.getInstance()));
    addTearDown(value.close);
    return (value, platform);
  }

  test(
    'confirmed zero restart survives old completion retry and preferences reload',
    () async {
      final f = await fixture();
      await f.remember();
      await f.save(0);
      f.server = _item(0);
      await f.acknowledge(0);
      expect(f.store.localProgress(f.account, 'movie'), isNull);
      expect(f.store.restartObserved(f.account, f.server), true);
      await expectLater(
        f.store.completions.syncOne(f.api, f.account, 'movie'),
        throwsA(isA<AppFailure>()),
      );
      expect(f.marks, 0);
      expect(f.store.completions.pending(f.account, 'movie'), true);
      await f.store.prefs.reload();
      expect(f.store.completions.superseded(f.account, 'movie'), true);
      final feed = HomeFeed(f.api, f.store);
      addTearDown(feed.dispose);
      await feed.afterPlayback(f.server, actualCompleted: false);
      await feed.refreshResume(force: true);
      expect(feed.resume, isEmpty);
      expect(f.store.restartObserved(f.account, f.server), true);
    },
  );

  for (final confirmed in [false, true]) {
    test(
      'new 45 second checkpoint without server date blocks old completion; confirmed=$confirmed',
      () async {
        final f = await fixture();
        await f.remember();
        await f.save(45);
        f.server = _item(45, date: null);
        if (confirmed) await f.acknowledge(45);
        await expectLater(
          f.store.completions.syncOne(f.api, f.account, 'movie'),
          throwsA(isA<AppFailure>()),
        );
        expect(f.marks, 0);
        expect(
          f.store.resume(f.account, f.server).position,
          const Duration(seconds: 45),
        );
        expect(f.store.completions.superseded(f.account, 'movie'), true);
        if (confirmed) {
          final feed = HomeFeed(f.api, f.store);
          addTearDown(feed.dispose);
          await feed.afterPlayback(f.server, actualCompleted: false);
          expect(feed.resume.single.resume, const Duration(seconds: 45));
          await feed.refreshResume(force: true);
          expect(
            feed.resume.single.resume,
            const Duration(seconds: 45),
            reason:
                'the old superseded EOF cannot project new positive progress to zero',
          );
        }
      },
    );
  }

  for (final seconds in [0, 45]) {
    test(
      'new $seconds second checkpoint waits for an already sent old completion',
      () async {
        final f = await fixture();
        await f.remember();
        f.markEntered = Completer<void>();
        f.markRelease = Completer<void>();
        final old = f.store.completions.syncOne(f.api, f.account, 'movie');
        await f.markEntered!.future;
        var saved = false;
        final fresh = f.save(seconds).then((_) => saved = true);
        await Future<void>.delayed(Duration.zero);
        expect(saved, false);
        expect(f.store.localProgress(f.account, 'movie'), isNull);
        f.markRelease!.complete();
        await old;
        await fresh;
        expect(f.store.completions.superseded(f.account, 'movie'), true);
        expect(
          f.store.localProgress(f.account, 'movie'),
          Duration(seconds: seconds),
        );
        // Model the new API report only after saveProgress returns, as Session does.
        f.server = _item(seconds, played: true);
        await f.acknowledge(seconds);
        await f.store.completions.syncOne(f.api, f.account, 'movie');
        expect(f.marks, 1);
        expect(
          f.store.resume(f.account, f.server).position,
          Duration(seconds: seconds),
        );
        if (seconds == 0) {
          expect(f.store.restartObserved(f.account, f.server), true);
        }
      },
    );
  }

  test(
    'new intent while old completion detail is in flight prevents mark before send',
    () async {
      final f = await fixture();
      await f.remember();
      f.readEntered = Completer<void>();
      f.readRelease = Completer<void>();
      final old = f.store.completions.syncOne(f.api, f.account, 'movie');
      final oldFailure = expectLater(old, throwsA(isA<AppFailure>()));
      await f.readEntered!.future;
      final fresh = f.save(45);
      await Future<void>.delayed(Duration.zero);
      f.readRelease!.complete();
      await oldFailure;
      await fresh;
      expect(f.marks, 0);
      expect(
        f.store.localProgress(f.account, 'movie'),
        const Duration(seconds: 45),
      );
    },
  );

  test(
    'ordinary genuine EOF remains eligible for automatic completion sync',
    () async {
      final f = await fixture();
      await f.remember();
      await f.save(0, completed: true);
      expect(f.store.completions.superseded(f.account, 'movie'), false);
      await f.store.completions.syncOne(f.api, f.account, 'movie');
      expect(f.marks, 1);
      expect(f.store.completions.pending(f.account, 'movie'), false);
    },
  );

  test(
    'superseded receipt can confirm Played read-only, and a new EOF restores normal sync',
    () async {
      final f = await fixture();
      await f.remember();
      await f.save(45);
      f.server = _item(45, played: true);
      await f.store.completions.syncOne(f.api, f.account, 'movie');
      expect(f.marks, 0);
      expect(f.store.completions.pending(f.account, 'movie'), false);
      expect(f.store.completions.superseded(f.account, 'movie'), true);
      await f.remember();
      await f.save(0, completed: true);
      f.server = _item(0);
      await f.store.completions.syncOne(f.api, f.account, 'movie');
      expect(f.marks, 1);
      expect(f.store.completions.superseded(f.account, 'movie'), false);
    },
  );

  test(
    'new EOF replacing a receipt during protection persistence is never superseded by old work',
    () async {
      final (f, platform) = await controlled();
      await f.remember();
      platform.delayProtection = true;
      var allowed = true;
      final old = f.save(45, allowed: () => allowed);
      await platform.entered.future;
      allowed = false;
      await f.remember();
      final freshAt = f.store.completions.receipt(f.account, 'movie')!['at'];
      await f.save(0, completed: true);
      platform.release.complete();
      await old;
      expect(f.store.completions.receipt(f.account, 'movie')!['at'], freshAt);
      expect(f.store.completions.superseded(f.account, 'movie'), false);
      expect(f.store.localProgress(f.account, 'movie'), Duration.zero);
    },
  );

  test(
    'a new EOF requested during an older running sync gets its own confirmation',
    () async {
      final f = await fixture();
      await f.remember();
      f.readEntered = Completer<void>();
      f.readRelease = Completer<void>();
      final old = f.store.completions.syncOne(f.api, f.account, 'movie');
      await f.readEntered!.future;
      await f.remember();
      final freshAt = f.store.completions.receipt(f.account, 'movie')!['at'];
      final fresh = f.store.completions.syncOne(f.api, f.account, 'movie');
      f.readRelease!.complete();
      await old;
      await fresh;
      expect(f.store.completions.receipt(f.account, 'movie')!['at'], freshAt);
      expect(f.store.completions.pending(f.account, 'movie'), false);
      expect(f.marks, 1);
    },
  );

  for (final throwing in [false, true]) {
    test(
      'failed protection persistence keeps actual checkpoint and warns; throwing=$throwing',
      () async {
        final (f, platform) = await controlled();
        await f.remember();
        platform.failProtection = !throwing;
        platform.throwProtection = throwing;
        await expectLater(
          f.save(45),
          throwsA(
            isA<AppFailure>().having(
              (e) => e.message,
              'failure',
              contains('保护标记保存失败'),
            ),
          ),
        );
        expect(
          f.store.localProgress(f.account, 'movie'),
          const Duration(seconds: 45),
        );
        expect(f.store.completions.superseded(f.account, 'movie'), true);
        await expectLater(
          f.store.completions.syncOne(f.api, f.account, 'movie'),
          throwsA(isA<AppFailure>()),
        );
        expect(f.marks, 0);
        platform.failProtection = false;
        platform.throwProtection = false;
        await f.save(45);
        await f.store.prefs.reload();
        expect(f.store.completions.superseded(f.account, 'movie'), true);
        expect(
          f.store.localProgress(f.account, 'movie'),
          const Duration(seconds: 45),
        );
      },
    );
    test(
      'protection failure still waits for an in-flight completion before saving new progress; throwing=$throwing',
      () async {
        final (f, platform) = await controlled();
        await f.remember();
        f.markEntered = Completer<void>();
        f.markRelease = Completer<void>();
        final old = f.store.completions.syncOne(f.api, f.account, 'movie');
        await f.markEntered!.future;
        final oldFailure = expectLater(old, throwsA(anything));
        platform.failProtection = !throwing;
        platform.throwProtection = throwing;
        final fresh = f.save(45);
        final freshFailure = expectLater(
          fresh,
          throwsA(
            isA<AppFailure>().having(
              (e) => e.message,
              'protection warning',
              contains('保护标记保存失败'),
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          f.store.localProgress(f.account, 'movie'),
          isNull,
          reason:
              'even a failed protection write cannot overtake an old sent mark',
        );
        f.markRelease!.complete();
        await oldFailure;
        await freshFailure;
        expect(
          f.store.localProgress(f.account, 'movie'),
          const Duration(seconds: 45),
        );
        platform.failProtection = false;
        platform.throwProtection = false;
        // A previous failed confirmation can look confirmed in the preferences
        // cache. Retry the unpersisted protection even in that state.
        await f.save(45);
        f.server = _item(45, played: true);
        await f.acknowledge(45);
        await f.store.prefs.reload();
        expect(f.store.completions.superseded(f.account, 'movie'), true);
        expect(
          f.store.resume(f.account, f.server).position,
          const Duration(seconds: 45),
        );
        expect(f.marks, 1);
      },
    );
  }

  test(
    'positive server date later than old EOF retains the existing remote-device safeguard',
    () async {
      final f = await fixture();
      await f.remember();
      final at = DateTime.parse(
        f.store.completions.receipt(f.account, 'movie')!['at'] as String,
      );
      f.server = _item(
        45,
        date: at.add(const Duration(seconds: 1)).toIso8601String(),
      );
      await expectLater(
        f.store.completions.syncOne(f.api, f.account, 'movie'),
        throwsA(isA<AppFailure>()),
      );
      expect(f.marks, 0);
      expect(f.store.completions.pending(f.account, 'movie'), true);
    },
  );
}
