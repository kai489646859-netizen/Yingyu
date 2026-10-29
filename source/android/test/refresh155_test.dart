import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/release_refresh.dart';
import 'manual_refresh_test.dart' show RefreshFixture;
import 'phone_layout_test.dart' show setDisplay;
import 'player_episode_menu_test.dart' show fonts;
import 'offline_capture.dart';
import 'offline_settle.dart';

void main() {
  setUpAll(fonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    syntheticImagePaths();
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  testWidgets('shared refresh never covers the first content row', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: ReleaseRefresh(
          busy: true,
          onRefresh: noRefresh,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: Text('继续观看', key: Key('first-row'))),
            ],
          ),
        ),
      ),
    );
    expect(find.text('正在刷新'), findsNothing);
    expect(find.byType(CupertinoActivityIndicator), findsNothing);
    expect(find.text('继续观看'), findsOneWidget);
  });

  testWidgets(
    'a short deliberate pull arms; release commits; prompt stays in gap',
    (tester) async {
      var calls = 0;
      final gate = Completer<void>();
      await tester.pumpWidget(
        CupertinoApp(
          home: ReleaseRefreshScrollView(
            onRefresh: () {
              calls++;
              return gate.future;
            },
            slivers: const [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 1500,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: Text('继续观看', key: Key('first-row')),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(200, 150));
      await gesture.moveBy(const Offset(0, 120));
      await tester.pump();
      expect(find.text('松手刷新'), findsOneWidget);
      expect(calls, 0);
      expect(
        tester.getRect(find.text('松手刷新')).bottom,
        lessThanOrEqualTo(
          tester.getRect(find.byKey(const Key('first-row'))).top,
        ),
      );
      await gesture.up();
      await tester.pump();
      expect(calls, 1);
      expect(find.text('正在刷新'), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
    },
  );
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    for (final dark in [false, true]) {
      testWidgets(
        'heading indicators follow shared refresh across pages $size dark=$dark',
        (tester) async {
          setDisplay(tester, size);
          final f = RefreshFixture(await SharedPreferences.getInstance());
          var page = 0;
          late StateSetter switchPage;
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(dark ? Brightness.dark : Brightness.light),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: StatefulBuilder(
                    builder: (context, change) {
                      switchPage = change;
                      return IndexedStack(
                        index: page,
                        children: [
                          HomeDashboard(
                            feed: f.feed,
                            active: page == 0,
                            onItem: (_) async {},
                            onPlay: (_) async {},
                            onResumeAll: () {},
                          ),
                          LibraryPage(
                            api: f.api,
                            browse: f.repo,
                            refreshFeed: f.feed,
                            active: page == 1,
                            onItem: (_) async {},
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          f.viewGate = Completer<void>();
          final job = f.feed.refresh(force: true);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          final all = find.byKey(const Key('resume-view-all'));
          final home = find.byKey(const Key('home-loading-indicator'));
          expect(home, findsOneWidget);
          expect(
            tester.getRect(home).left,
            greaterThanOrEqualTo(tester.getRect(all).right),
          );
          expect(find.text('正在刷新'), findsNothing);
          await captureOffline(
            tester,
            boundary,
            'refresh155-home-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
          );
          switchPage(() => page = 1);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 200));
          expect(
            find.byKey(const Key('library-loading-indicator')),
            findsOneWidget,
          );
          expect(find.text('正在刷新'), findsNothing);
          await captureOffline(
            tester,
            boundary,
            'refresh155-library-${size.width.toInt()}-${dark ? 'dark' : 'light'}',
          );
          f.viewGate!.complete();
          f.viewGate = null;
          var done = false;
          unawaited(job.then((_) => done = true));
          for (var n = 0; n < 150 && !done; n++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(done, true);
          await settleOffline(tester);
          expect(
            find.byKey(const Key('library-loading-indicator')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          f.dispose();
        },
      );
    }
  }
}

Future<void> noRefresh() async {}
