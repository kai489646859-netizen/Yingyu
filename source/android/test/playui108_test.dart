import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/adjustment_panels.dart';
import 'package:yingyu/playback/audio_balance.dart';
import 'package:yingyu/playback/audio_balance_menu.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession;
import 'interaction101_test.dart' show DeferredAdjustments;
import 'audio_balance106_ui_test.dart' show BalanceBackend;
import 'player_episode_menu_test.dart' show fonts;

void main() {
  setUpAll(fonts);
  testWidgets('status network and battery stay white under every theme', (
    tester,
  ) async {
    for (final accent in AppAccent.available) {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark, accentChoice: accent),
          home: Scaffold(
            body: PlayerStatusBar(
              data: PlayerStatusData(
                time: DateTime(2026, 10, 20, 12),
                network: 'wifi',
                batteryPercent: 42,
                charging: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final icon = find.byIcon(Icons.wifi);
      final widget = tester.widget<Icon>(icon);
      expect(
        widget.color ?? IconTheme.of(tester.element(icon)).color,
        Colors.white,
      );
      final fills = tester
          .widgetList<ColoredBox>(
            find.descendant(
              of: find.byType(PlayerBattery),
              matching: find.byType(ColoredBox),
            ),
          )
          .map((w) => w.color);
      expect(fills, contains(Colors.white));
    }
  });

  testWidgets('format information remains readable for five visible seconds', (
    tester,
  ) async {
    var done = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SourceFormatNotice(text: 'HDR10 · 高动态范围', onDone: () => done++),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('source-notice')), findsOneWidget);
    expect(done, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('source-notice')), findsNothing);
    expect(done, 1);
  });

  Future<(AppStore, EmbyClient, PlaybackSession)> sessionFor(
    PlayerBackend backend,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    final api = EmbyClient(
      client: MockClient((_) async => throw StateError('No network')),
    )..session = syntheticSession();
    final session =
        PlaybackSession(
            api: api,
            store: store,
            item: MediaItem({'Id': 'synthetic'}),
            backend: backend,
          )
          ..ready = true
          ..loading = false;
    return (store, api, session);
  }

  Future<void> cleanup(
    WidgetTester tester,
    AppStore store,
    EmbyClient api,
    PlaybackSession session,
  ) async {
    await tester.pumpWidget(const SizedBox());
    session.ready = false;
    await session.close();
    session.dispose();
    api.close();
    store.log.dispose();
    store.dispose();
  }

  testWidgets(
    'subtitle adjustment does not flash buttons disabled on each acknowledgement',
    (tester) async {
      final backend = DeferredAdjustments();
      final (store, api, session) = await sessionFor(backend);
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: SubtitlePositionMenu(session: session, onBack: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final panel = tester.element(find.byType(SubtitlePositionMenu));
      final up = find.widgetWithText(CupertinoButton, '上移 5%');
      final reset = find.widgetWithText(CupertinoButton, '恢复默认位置');
      for (final target in [25.0, 50.0, 75.0]) {
        final gate = backend.pendingPosition = Completer<void>();
        tester
            .widget<CupertinoSlider>(
              find.byKey(const Key('subtitle-position-slider')),
            )
            .onChanged!(target);
        await tester.pump();
        final upEnabled = tester.widget<CupertinoButton>(up).onPressed != null;
        final resetEnabled =
            tester.widget<CupertinoButton>(reset).onPressed != null;
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          upEnabled && resetEnabled,
          true,
          reason:
              'Busy acknowledgements must not repeatedly dim the panel controls',
        );
        expect(tester.element(find.byType(SubtitlePositionMenu)), same(panel));
        expect(session.closed, false);
      }
      await cleanup(tester, store, api, session);
    },
  );

  testWidgets(
    'audio menu explains and applies the change in the current session',
    (tester) async {
      final backend = BalanceBackend();
      final (store, api, session) = await sessionFor(backend);
      await store.setAudioBalanceEnabled(true);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(body: AudioBalanceMenu(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('立即应用'), findsOneWidget);
      await tester.tap(find.text(AudioBalance.gentle.label));
      await tester.pumpAndSettle();
      expect(backend.calls, [AudioBalance.gentle]);
      expect(backend.audioBalance, AudioBalance.gentle);
      expect(store.audioBalance, AudioBalance.gentle);
      await cleanup(tester, store, api, session);
    },
  );
}
