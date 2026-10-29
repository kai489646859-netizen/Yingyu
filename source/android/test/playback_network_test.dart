import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/network_permission.dart';
import 'package:yingyu/playback/cache_policy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'upgrades default to no retained playback cache and ask before mobile playback',
    () async {
      SharedPreferences.setMockInitialValues({'yingyu.images.gb.v1': 10});
      final store = AppStore(await SharedPreferences.getInstance());
      expect(store.playbackCacheGB, 0);
      expect(store.allowMobilePlayback, false);
      expect(playbackCacheChoices.keys, [0, 2, 5, 10, 20, 50, -1]);
      await store.setAllowMobilePlayback(true);
      expect(
        AppStore(await SharedPreferences.getInstance()).allowMobilePlayback,
        true,
      );
      expect(store.prefs.getInt('yingyu.images.gb.v1'), 10);
    },
  );
  for (final state in ['mobile', 'metered', 'unknown']) {
    testWidgets(
      '$state asks before media is prepared, cancellation never opens it',
      (tester) async {
        var opens = 0, setting = false;
        final permission = PlaybackNetworkPermission(
          allowed: () => setting,
          read: () async => state,
        );
        await tester.pumpWidget(
          CupertinoApp(
            home: Builder(
              builder: (context) => CupertinoButton(
                onPressed: () async {
                  if (await permission.authorize(context)) opens++;
                },
                child: const Text('播放'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('播放'));
        await tester.pumpAndSettle();
        expect(opens, 0);
        expect(find.text('继续播放'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(opens, 0);
        await tester.tap(find.text('播放'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('继续播放'));
        await tester.pumpAndSettle();
        expect(opens, 1);
        expect(setting, false);
        await tester.tap(find.text('播放'));
        await tester.pumpAndSettle();
        expect(opens, 2);
        expect(find.text('继续播放'), findsNothing);
      },
    );
  }
  for (final allowed in [false, true]) {
    testWidgets('unmetered playback proceeds immediately, switch=$allowed', (
      tester,
    ) async {
      var opens = 0;
      final permission = PlaybackNetworkPermission(
        allowed: () => allowed,
        read: () async => 'unmetered',
      );
      await tester.pumpWidget(
        CupertinoApp(
          home: Builder(
            builder: (context) => CupertinoButton(
              onPressed: () async {
                if (await permission.authorize(context)) opens++;
              },
              child: const Text('播放'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('播放'));
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(find.text('继续播放'), findsNothing);
    });
  }
  testWidgets('enabled mobile switch proceeds without a dialog', (
    tester,
  ) async {
    var opens = 0;
    final permission = PlaybackNetworkPermission(
      allowed: () => true,
      read: () async => 'mobile',
    );
    await tester.pumpWidget(
      CupertinoApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            onPressed: () async {
              if (await permission.authorize(context)) opens++;
            },
            child: const Text('播放'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(find.text('继续播放'), findsNothing);
  });
}
