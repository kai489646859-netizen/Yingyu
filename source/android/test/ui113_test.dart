import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/info.dart';
import 'package:yingyu/playback/media_facts.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/ui/swipe_pages.dart';
import 'core_test.dart' show syntheticSession;
import 'playback_test.dart' show FakeBackend;
import 'host/start104/position.dart' as position;

class _Facts extends FakeBackend implements PlaybackFactsBackend {
  int reads = 0;
  @override
  PlaybackMediaFacts get mediaFacts {
    reads++;
    return const PlaybackMediaFacts({'video-format': 'hevc'});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ordinary bitmap starts at its actual displayed position', () async {
    final h = position.PositionReadHarness()..regular();
    h.io.values['yingyu-subtitle-position'] = '82.5';
    expect(await h.readSubtitlePosition(allowed: () => true), 17.5);
    expect(h.io.reads, ['yingyu-subtitle-position']);
  });
  testWidgets('playback clock ticks do not rebuild the information list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(await SharedPreferences.getInstance());
    await store.log.setEnabled(false);
    final api = EmbyClient(
      client: MockClient((_) async => throw StateError('No IO')),
    )..session = syntheticSession();
    final backend = _Facts();
    final session =
        PlaybackSession(
            api: api,
            store: store,
            item: MediaItem({'Id': 'movie', 'Name': 'Synthetic'}),
            backend: backend,
          )
          ..ready = true
          ..loading = false;
    await tester.pumpWidget(
      MaterialApp(home: PlaybackInfoPage(session: session)),
    );
    final before = backend.reads;
    for (var n = 0; n < 40; n++) {
      session.changed();
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(backend.reads - before, lessThanOrEqualTo(2));
    final scrollable = find.byType(Scrollable).first;
    final finger = await tester.startGesture(tester.getCenter(scrollable));
    await finger.moveBy(const Offset(0, -30));
    await tester.pump();
    final duringScroll = backend.reads;
    for (var n = 0; n < 6; n++) {
      session.changed();
      await finger.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(backend.reads, duringScroll);
    await finger.up();
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(scrollable).position;
    final offset = position.pixels;
    expect(offset, greaterThan(0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(backend.reads, greaterThan(duringScroll));
    expect(position.pixels, offset);
    await tester.pumpWidget(const SizedBox());
    session.ready = false;
    await session.close();
    api.close();
    store.log.dispose();
    store.dispose();
  });
  testWidgets('one horizontal gesture has one continuous scroll activity', (
    tester,
  ) async {
    var starts = 0, ends = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: NotificationListener<ScrollNotification>(
          onNotification: (event) {
            if (event.metrics.axis == Axis.horizontal) {
              if (event is ScrollStartNotification) starts++;
              if (event is ScrollEndNotification) ends++;
            }
            return false;
          },
          child: SwipePages(
            index: 0,
            onChanged: (_) {},
            children: const [
              ColoredBox(color: Colors.red),
              ColoredBox(color: Colors.blue),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(600, 300));
    for (var n = 0; n < 15; n++) {
      await gesture.moveBy(const Offset(-25, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(ends, 1);
  });
}
