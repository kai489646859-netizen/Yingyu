import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Model delayed platform persistence without reading any device preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show response, syntheticSession;
import 'home_feed_test.dart' show entry;

class DelayedRestartPreferences extends InMemorySharedPreferencesStore {
  DelayedRestartPreferences() : super.withData({});
  var holdBaseline = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    final result = await super.setValue(type, key, value);
    if (holdBaseline && key.endsWith('.baseline')) {
      holdBaseline = false;
      entered.complete();
      await release.future;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DelayedRestartPreferences platform;
  late AppStore store;
  final account = syntheticSession();
  final first = entry('restart', seconds: 0);
  final latest = entry('restart', seconds: 0, date: '2026-10-16T03:00:00Z');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    platform = DelayedRestartPreferences();
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = platform;
    addTearDown(() => SharedPreferencesStorePlatform.instance = previous);
    store = AppStore(await SharedPreferences.getInstance());
    await store.saveProgress(
      account,
      first.id,
      Duration.zero,
      serverBaseline: first,
      keepZeroDisplay: true,
    );
  });
  tearDown(() async {
    await store.log.flush();
    store.dispose();
  });

  test(
    'old zero readback waiting on disk cannot bind a newer zero intent',
    () async {
      final oldReply = entry(
        'restart',
        seconds: 0,
        date: '2026-10-16T02:00:00Z',
      );
      platform.holdBaseline = true;
      final old = store.observeProgress(account, oldReply, Duration.zero);
      await platform.entered.future;
      await store.saveProgress(
        account,
        latest.id,
        Duration.zero,
        serverBaseline: latest,
        keepZeroDisplay: true,
      );
      platform.release.complete();
      await old;
      expect(store.restartObserved(account, latest), true);
      expect(store.restartObserved(account, oldReply), false);
      await store.prefs.reload();
      expect(store.restartObserved(account, latest), true);
      expect(store.localProgress(account, latest.id), Duration.zero);
    },
  );

  test(
    'superseded same-zero checkpoint cannot clear or replace latest evidence',
    () async {
      var allowed = true;
      platform.holdBaseline = true;
      final old = store.saveProgress(
        account,
        first.id,
        Duration.zero,
        serverBaseline: first,
        allowed: () => allowed,
      );
      await platform.entered.future;
      allowed = false;
      await store.saveProgress(
        account,
        latest.id,
        Duration.zero,
        serverBaseline: latest,
        keepZeroDisplay: true,
      );
      platform.release.complete();
      await old;
      expect(store.restartObserved(account, latest), true);
      expect(store.restartObserved(account, first), false);
      expect(store.localProgress(account, latest.id), Duration.zero);
    },
  );

  test(
    'delayed background readback cannot confirm a newer same-zero restart',
    () async {
      final entered = Completer<void>(), result = Completer<http.Response>();
      final api = EmbyClient(
        client: MockClient((_) {
          entered.complete();
          return result.future;
        }),
      )..session = account;
      addTearDown(api.close);
      final old = store.retryPendingProgress(api, account);
      await entered.future;
      await store.saveProgress(
        account,
        latest.id,
        Duration.zero,
        serverBaseline: latest,
        keepZeroDisplay: true,
      );
      result.complete(response(jsonEncode(first.data), 200));
      await old;
      expect(store.localProgress(account, latest.id), Duration.zero);
      expect(store.restartObserved(account, latest), true);
      expect(store.restartObserved(account, first), false);
      await store.prefs.reload();
      expect(store.localProgress(account, latest.id), Duration.zero);
    },
  );
}
