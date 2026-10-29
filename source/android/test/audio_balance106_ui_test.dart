import 'dart:convert';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/audio_balance.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/settings.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'core_test.dart' show syntheticSession, playbackData, response;
import 'track_menu_test.dart' show MenuBackend;
import 'offline_settle.dart' show settleOffline;

class BalanceBackend extends MenuBackend implements AudioBalanceBackend {
  @override
  AudioBalance audioBalance = AudioBalance.original;
  final calls = <AudioBalance>[];
  bool reject = false;
  Completer<void>? effectGate;
  @override
  Future<AudioBalance> setAudioBalance(
    AudioBalance value, {
    required bool Function() allowed,
  }) async {
    if (!allowed()) throw const AppFailure('closed');
    calls.add(value);
    if (effectGate != null) await effectGate!.future;
    if (!allowed()) throw const AppFailure('closed');
    if (reject) throw const AppFailure('synthetic filter unavailable');
    return audioBalance = value;
  }
}

EmbyClient apiForBalance() => EmbyClient(
  client: MockClient(
    (r) async => r.url.path.endsWith('PlaybackInfo')
        ? response(jsonEncode(playbackData()), 200)
        : r.url.path.contains('Sessions/Playing')
        ? response('', 204)
        : response('{"Id":"movie","Type":"Movie"}', 200),
  ),
)..session = syntheticSession();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'enabling exposes controls without changing the default sound',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      expect(store.audioBalanceEnabled, false);
      expect(store.audioBalance, AudioBalance.original);
      await store.setAudioBalanceEnabled(true);
      expect(store.audioBalance, AudioBalance.original);
      await store.setAudioBalance(AudioBalance.gentle);
      await store.setAudioBalanceEnabled(false);
      await store.setAudioBalanceEnabled(true);
      expect(store.audioBalance, AudioBalance.gentle);
      store.log.dispose();
      store.dispose();
    },
  );
  for (final (enabled, mode, reject) in [
    (false, AudioBalance.night, false),
    (true, AudioBalance.original, false),
    (true, AudioBalance.gentle, false),
    (true, AudioBalance.night, true),
  ]) {
    test(
      'opening enabled=$enabled mode=$mode rejected=$reject preserves normal play',
      () async {
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        await store.setAudioBalanceEnabled(enabled);
        await store.setAudioBalance(mode);
        final api = apiForBalance();
        final backend = BalanceBackend()
          ..gate.complete()
          ..reject = reject;
        final session = PlaybackSession(
          api: api,
          store: store,
          item: MediaItem({'Id': 'movie'}),
          backend: backend,
        );
        await session.open();
        await Future<void>.delayed(Duration.zero);
        expect(session.ready, true);
        expect(session.error, isNull);
        expect(backend.snapshot.playing, true);
        expect(
          backend.calls,
          enabled && mode != AudioBalance.original ? [mode] : isEmpty,
        );
        expect(session.audioBalanceWarning, reject ? isNotNull : isNull);
        expect(backend.selectedAudioId, '1');
        await session.close();
        session.dispose();
        api.close();
        await store.log.flush();
        store.log.dispose();
        store.dispose();
      },
    );
  }
  test(
    'a stalled optional audio controller cannot hold startup or close',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      await store.setAudioBalanceEnabled(true);
      await store.setAudioBalance(AudioBalance.standard);
      final api = apiForBalance();
      final gate = Completer<void>();
      final backend = BalanceBackend()
        ..gate.complete()
        ..effectGate = gate;
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      );
      await session.open().timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(gate.isCompleted, false);
      expect(backend.calls, [AudioBalance.standard]);
      expect(session.ready, true);
      expect(session.loading, false);
      expect(backend.snapshot.playing, true);
      await session.close().timeout(const Duration(seconds: 1));
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(backend.audioBalance, AudioBalance.original);
      expect(session.audioBalanceWarning, isNull);
      expect(store.audioBalance, AudioBalance.standard);
      session.dispose();
      api.close();
      await store.log.flush();
      store.log.dispose();
      store.dispose();
    },
  );
  testWidgets('settings switch is marked test and never selects a preset', (
    tester,
  ) async {
    final store = AppStore(await SharedPreferences.getInstance());
    final api = apiForBalance();
    final repo = BrowseRepository(
      api,
      BrowseCache(store.prefs),
      BrowsePreferences(store.prefs),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark),
        home: Scaffold(
          body: SettingsPage(store: store, browse: repo),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('音量均衡（测试）'), 300);
    expect(find.text('原生 HDR（测试）'), findsOneWidget);
    expect(find.text('原生 HDR（试用）'), findsNothing);
    final row = find.ancestor(
      of: find.text('音量均衡（测试）'),
      matching: find.byType(SettingsRow),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byType(CupertinoSwitch)),
    );
    await tester.pumpAndSettle();
    expect(store.audioBalanceEnabled, true);
    expect(store.audioBalance, AudioBalance.original);
    await tester.pumpWidget(const SizedBox());
    repo.dispose();
    api.close();
    store.log.dispose();
    store.dispose();
  });
  testWidgets(
    'player menu appears only after opt-in; changes while paused retain selection and pause',
    (tester) async {
      final store = AppStore(await SharedPreferences.getInstance());
      await store.log.setEnabled(false);
      final api = apiForBalance();
      final backend = BalanceBackend();
      final session = PlaybackSession(
        api: api,
        store: store,
        item: MediaItem({'Id': 'movie'}),
        backend: backend,
      )..ready = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: PlayerMenu(
            session: session,
            fit: BoxFit.contain,
            onToggle: () {},
            onSeek: (_) {},
          ),
        ),
      );
      expect(find.text('音量均衡'), findsNothing);
      await store.setAudioBalanceEnabled(true);
      await tester.pumpAndSettle();
      expect(find.text('音量均衡'), findsOneWidget);
      expect(backend.calls, isEmpty);
      await tester.tap(find.text('音量均衡'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('夜间模式'));
      await tester.pumpAndSettle();
      expect(store.audioBalance, AudioBalance.night);
      expect(backend.audioBalance, AudioBalance.night);
      expect(backend.snapshot.playing, false);
      expect(backend.selectedAudioId, '1');
      final selected = find.ancestor(
        of: find.text('夜间模式'),
        matching: find.byType(SelectionRow),
      );
      expect(tester.widget<SelectionRow>(selected).selected, true);
      await tester.tap(find.text('原始声音'));
      await tester.pumpAndSettle();
      expect(store.audioBalance, AudioBalance.original);
      expect(backend.snapshot.playing, false);
      await tester.runAsync(session.close);
      await tester.pumpWidget(const SizedBox());
      await settleOffline(tester);
      session.dispose();
      api.close();
      store.log.dispose();
      store.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
