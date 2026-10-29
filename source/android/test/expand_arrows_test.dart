import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/account_display.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/playback/episode_menu.dart';
import 'package:yingyu/ui/account_avatar.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/release_notes.dart';
import 'package:yingyu/version.dart';
import 'core_test.dart' show syntheticSession, response;
import 'player_episode_menu_test.dart' show catalogueApi, episode, launch;

void expectArrow(Finder owner, bool expanded) {
  final rotation = find.descendant(
    of: owner,
    matching: find.byType(RotationTransition),
  );
  expect(rotation, findsOneWidget);
  expect(
    (rotation.evaluate().single.widget as RotationTransition).turns.value,
    closeTo(expanded ? .25 : 0, .0001),
  );
}

void main() {
  for (final card in [false, true]) {
    testWidgets(
      'account selector arrow follows the open selector lifetime card=$card',
      (tester) async {
        final closed = Completer<void>();
        Future<void> open() => closed.future;
        final account = syntheticSession();
        const display = AccountDisplay(color: 0);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: card
                    ? AccountCard(
                        account: account,
                        display: display,
                        onTap: open,
                      )
                    : AccountSwitchButton(
                        account: account,
                        display: display,
                        onTap: open,
                      ),
              ),
            ),
          ),
        );
        final button = find.byKey(
          Key(card ? 'account-avatar-switch' : 'quick-account-switch'),
        );
        expectArrow(button, false);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expectArrow(button, true);
        closed.complete();
        await tester.pumpAndSettle();
        expectArrow(button, false);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('library arrow restores after back, selection and rotation', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 600);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = EmbyClient(
      client: MockClient(
        (_) async => response('{"Items":[],"TotalRecordCount":0}', 200),
      ),
    )..session = syntheticSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryPage(api: api, onItem: (_) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final picker = find.byKey(const Key('library-picker'));
    expectArrow(picker, false);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expectArrow(picker, true);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expectArrow(picker, false);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('library-choice-all')));
    await tester.pumpAndSettle();
    expectArrow(picker, false);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(600, 800);
    await tester.pumpAndSettle();
    expectArrow(picker, false);
    await tester.pumpWidget(const SizedBox());
    api.close();
    expect(tester.takeException(), isNull);
  });
  testWidgets('episode range arrow restores after choosing and dismissing', (
    tester,
  ) async {
    final api = catalogueApi();
    await launch(tester, EpisodeMenuData(api), episode(1));
    final picker = find.byKey(const Key('player-episode-range'));
    expectArrow(picker, false);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expectArrow(picker, true);
    await tester.tap(find.text('51–100'));
    await tester.pumpAndSettle();
    expectArrow(picker, false);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    expectArrow(picker, true);
    Navigator.of(tester.element(find.byType(EpisodeMenu))).pop();
    await tester.pumpAndSettle();
    expectArrow(picker, false);
    await tester.pumpWidget(const SizedBox());
    api.close();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'release expansion arrow is right when closed and down when open',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ReleaseNotesPage())),
      );
      await tester.pumpAndSettle();
      final tile = find.byKey(const PageStorageKey('release-$appVersion'));
      expectArrow(tile, true);
      await tester.tap(find.text('$appVersion · 当前版本'));
      await tester.pumpAndSettle();
      expectArrow(tile, false);
      await tester.tap(find.text('$appVersion · 当前版本'));
      await tester.pumpAndSettle();
      expectArrow(tile, true);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
