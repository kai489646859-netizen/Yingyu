import 'package:yingyu/ui/release_refresh.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/poster_motion.dart';
import 'poster_opacity.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'core_test.dart' show response, syntheticSession;
import 'offline_settle.dart';

void main() {
  setUp(() {
    syntheticImagePaths();
    SharedPreferences.setMockInitialValues({});
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });
  testWidgets(
    'catalogue pull refresh keeps old rows, coalesces calls and restarts automatic interval',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      var calls = 0, views = 0, validations = 0;
      var now = DateTime.utc(2026, 10, 7);
      Completer<void>? gate;
      var fail = false;
      final api = EmbyClient(
        client: MockClient((request) async {
          if (request.url.path.endsWith('/Views')) {
            views++;
            return response('{"Items":[]}', 200);
          }
          if (request.url.queryParameters['Ids'] != null) {
            validations++;
            final ids = request.url.queryParameters['Ids']!.split(',');
            return response(
              jsonEncode({
                'Items': [
                  for (final id in ids) {'Id': id},
                ],
                'TotalRecordCount': ids.length,
              }),
              200,
            );
          }
          calls++;
          if (gate != null) await gate.future;
          if (fail) return response('{"Message":"synthetic unavailable"}', 500);
          return response(
            jsonEncode({
              'Items': [
                {'Id': 'a', 'Name': 'A first', 'Type': 'Movie'},
                if (calls > 1) {'Id': 'b', 'Name': 'B new', 'Type': 'Movie'},
              ],
              'TotalRecordCount': calls > 1 ? 2 : 1,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        spacing: Duration.zero,
        now: () => now,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
          ),
        ),
      );
      await settleOffline(tester);
      expect(calls, 1);
      expect(find.text('A first'), findsOneWidget);
      now = now.add(repo.preferences.interval - const Duration(seconds: 5));
      await tester.pump(repo.preferences.interval - const Duration(seconds: 5));
      gate = Completer<void>();
      // Actual drag on a short catalogue must work (always-scrollable physics).
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 360));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(calls, 2);
      expect(find.text('A first'), findsOneWidget);
      final pull = tester.widget<ReleaseRefreshScrollView>(
        find.byType(ReleaseRefreshScrollView),
      );
      var done = false;
      final joined = pull.onRefresh().then((_) => done = true);
      now = now.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 10));
      expect(
        calls,
        2,
        reason: 'old automatic deadline cannot overlap manual refresh',
      );
      expect(done, false);
      gate.complete();
      gate = null;
      await settleOffline(tester);
      await joined;
      expect(
        validations,
        0,
        reason: 'complete manual directory replaces redundant cached ID probes',
      );
      expect(find.text('B new'), findsOneWidget);
      expect(
        views,
        1,
        reason:
            'current catalogue refresh does not refetch home sections or account',
      );
      now = now.add(repo.preferences.interval - const Duration(minutes: 1));
      await tester.pump(repo.preferences.interval - const Duration(minutes: 1));
      await settleOffline(tester);
      expect(calls, 2);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      await settleOffline(tester);
      expect(calls, 3);
      fail = true;
      final failed = pull.onRefresh();
      await settleOffline(tester);
      await failed;
      expect(find.text('A first'), findsOneWidget);
      expect(find.text('B new'), findsOneWidget);
      expect(calls, 4);
      await tester.pumpWidget(const SizedBox());
      repo.dispose();
      api.close();
      expect(tester.takeException(), null);
    },
  );

  for (final reduce in [false, true]) {
    testWidgets(
      'poster appearance respects large jumps and reduced motion=$reduce',
      (tester) async {
        final scroll = ScrollController();
        var taps = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: PosterMotionScope(
              reducedMotion: reduce,
              child: ListView.builder(
                controller: scroll,
                scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                itemExtent: 160,
                itemCount: 50,
                itemBuilder: (_, i) => PosterEntrance(
                  key: ValueKey('entrance$i'),
                  id: '$i',
                  child: GestureDetector(
                    onTap: () => taps++,
                    child: Text('poster$i'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        double opacity(int i) =>
            posterOpacity(tester, find.byKey(ValueKey('entrance$i')));
        expect(opacity(0), 1, reason: 'opening a page must stay still');
        await tester.pump(const Duration(milliseconds: 230));
        expect(opacity(0), 1);
        await tester.tap(find.text('poster0'));
        expect(taps, 1);
        final gesture = await tester.startGesture(const Offset(400, 300));
        await gesture.moveBy(const Offset(0, -20));
        await gesture.moveBy(const Offset(0, -80));
        await tester.pump();
        await tester.pump();
        expect(opacity(4), 1);
        await tester.pump(const Duration(milliseconds: 230));
        await gesture.up();
        scroll.jumpTo(4000);
        await tester.pump();
        await tester.pump();
        expect(opacity(25), 1, reason: 'large jump displays cards immediately');
        await tester.pump(const Duration(milliseconds: 200));
        scroll.jumpTo(0);
        await tester.pump();
        await tester.pump();
        expect(
          opacity(0),
          1,
          reason: 'large jump back displays recycled cards immediately',
        );
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        expect(tester.takeException(), null);
      },
    );
  }
  testWidgets(
    'alphabet drag and system reduced motion finish appearance immediately',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: PosterMotionScope(
            child: PosterEntrance(id: 'one', child: Text('one')),
          ),
        ),
      );
      await tester.pump();
      final owner = Object();
      PosterDemand.pause(owner, true);
      await tester.pump();
      expect(posterOpacity(tester, find.byType(PosterEntrance)), 1);
      PosterDemand.pause(owner, false);
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: PosterMotionScope(
              child: PosterEntrance(id: 'two', child: Text('two')),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(posterOpacity(tester, find.byType(PosterEntrance)), 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
