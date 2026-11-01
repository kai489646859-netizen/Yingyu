import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/audio_balance.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/login.dart';
import 'package:yingyu/ui/style.dart';
import 'audio_balance106_ui_test.dart' show BalanceBackend, apiForBalance;
import 'audio_balance106_test.dart' show FilterIo;
import 'offline_capture.dart';
import 'offline_settle.dart';
import 'scroll_affordance_test.dart' show fonts;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'voice failure restores the exact tempo and previous preset chain',
    () async {
      final io = FilterIo(), control = AudioBalanceControl();
      await io.set(control, AudioBalance.gentle);
      final before = io.filters;
      io.rejectOnce = true;
      await expectLater(
        io.set(control, AudioBalance.voice),
        throwsA(isA<AppFailure>()),
      );
      expect(io.filters, before);
      expect(control.value, AudioBalance.gentle);
      await io.set(control, AudioBalance.voice);
      await io.set(control, AudioBalance.original);
      expect(io.filters, 'scaletempo2');
    },
  );
  for (final size in [
    const Size(360, 800),
    const Size(800, 360),
    const Size(1280, 800),
  ]) {
    for (final brightness in Brightness.values) {
      final name =
          '${size.width.toInt()}-${size.height.toInt()}-${brightness.name}';
      testWidgets(
        'login uses original Yingyu asset and voice selection survives reopen $name',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.display.size = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.display.resetSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final capture = GlobalKey();
          Widget shell(Widget child) => RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme(brightness),
              home: child,
            ),
          );
          await tester.pumpWidget(shell(LoginPage(login: (_, _, _) async {})));
          await tester.pumpAndSettle();
          final icon = tester.widget<Image>(
            find.byKey(const Key('login-yingyu-icon')),
          );
          expect((icon.image as AssetImage).assetName, 'assets/yingyu.png');
          expect(icon.color, isNull);
          expect(find.text('连接你的媒体库'), findsOneWidget);
          await captureOffline(tester, capture, 'voice202-login-$name');
          final store = AppStore(await SharedPreferences.getInstance());
          await store.log.setEnabled(false);
          await store.setAudioBalanceEnabled(true);
          final api = apiForBalance(), backend = BalanceBackend();
          final session = PlaybackSession(
            api: api,
            store: store,
            item: MediaItem({'Id': 'synthetic-movie'}),
            backend: backend,
          )..ready = true;
          Widget menu() => PlayerMenu(
            session: session,
            initialPane: 'audioBalance',
            fit: BoxFit.contain,
            onToggle: () {},
            onSeek: (_) {},
          );
          await tester.pumpWidget(shell(menu()));
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('人声增强'), 100);
          await tester.pumpAndSettle();
          await tester.tap(find.text('人声增强'));
          await tester.pumpAndSettle();
          expect(backend.audioBalance, AudioBalance.voice);
          expect(backend.snapshot.playing, isFalse);
          expect(backend.selectedAudioId, '1');
          expect(store.audioBalance, AudioBalance.voice);
          final reopened = AppStore(await SharedPreferences.getInstance());
          expect(reopened.audioBalance, AudioBalance.voice);
          reopened.log.dispose();
          reopened.dispose();
          await captureOffline(tester, capture, 'voice202-menu-$name');
          await tester.scrollUntilVisible(find.text('原始声音'), -100);
          await tester.pumpAndSettle();
          await tester.tap(find.text('原始声音'));
          await tester.pumpAndSettle();
          expect(backend.audioBalance, AudioBalance.original);
          expect(backend.snapshot.playing, isFalse);
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
  }
}
