import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/server_resume.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/continue_watching.dart';

import 'core_test.dart' show response, syntheticSession;

MediaItem episode(
  String id, {
  bool played = false,
  int seconds = 0,
  double? percentage,
}) => MediaItem({
  'Id': id,
  'Name': id,
  'Type': 'Episode',
  'SeriesId': 'series-$id',
  'IndexNumber': 30,
  'UserData': {
    'Played': played,
    'PlaybackPositionTicks': ticks(Duration(seconds: seconds)),
    'PlayedPercentage': ?percentage,
  },
});

void main() {
  setUp(() {
    final controller = VisibilityDetectorController.instance;
    final interval = controller.updateInterval;
    controller.updateInterval = Duration.zero;
    addTearDown(() => controller.updateInterval = interval);
  });

  testWidgets('home retains progress tracks when Resume omits runtime', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1700, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(await SharedPreferences.getInstance());
    final api = EmbyClient()..session = syntheticSession();
    final feed = HomeFeed(api, store)
      ..resume = [
        ServerResumeItem(episode('resume', seconds: 2261)),
        ServerResumeItem(episode('rewatch', played: true, seconds: 1206)),
        ServerResumeItem(
          episode('ratio', played: true, seconds: 37, percentage: 25),
        ),
        CompletedResumeItem(episode('complete', played: true)),
        NextResumeItem(episode('next')),
      ];
    addTearDown(() {
      feed.dispose();
      api.close();
      store.log.dispose();
      store.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContinueWatching(
            feed: feed,
            active: false,
            onPlay: (_) async {},
            onDetail: (_) async {},
          ),
        ),
      ),
    );
    final values = {
      'resume': 0.0,
      'rewatch': 1.0,
      'ratio': .25,
      'complete': 1.0,
    };
    for (final entry in values.entries) {
      final bar = find.byKey(ValueKey('resume-progress-${entry.key}'));
      expect(bar, findsOneWidget, reason: entry.key);
      expect(tester.widget<LinearProgressIndicator>(bar).value, entry.value);
    }
    expect(find.byKey(const ValueKey('resume-progress-next')), findsNothing);
    expect(find.textContaining('37:41'), findsOneWidget);
    expect(find.textContaining('20:06'), findsOneWidget);
    expect(feed.resume[1].resume, const Duration(seconds: 1206));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('view-all shows the same track and preserves the play position', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(await SharedPreferences.getInstance());
    final item = episode('sparse', seconds: 2261);
    final api = EmbyClient(
      client: MockClient(
        (request) async => response(
          jsonEncode({
            'Items': [if (request.url.path.endsWith('/Resume')) item.data],
            'TotalRecordCount': request.url.path.endsWith('/Resume') ? 1 : 0,
          }),
          200,
        ),
      ),
    )..session = syntheticSession();
    final feed = HomeFeed(api, store);
    addTearDown(() {
      feed.dispose();
      api.close();
      store.log.dispose();
      store.dispose();
    });
    Duration? playedAt;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryPage(
            api: api,
            resumeFeed: feed,
            onItem: (_) async {},
            onPlay: (row) async => playedAt = row.resume,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bar = find.byKey(const ValueKey('resume-progress-sparse'));
    expect(bar, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(bar).value, 0);
    expect(find.textContaining('37:41'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('resume-play-sparse')));
    await tester.pumpAndSettle();
    expect(playedAt, const Duration(seconds: 2261));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
