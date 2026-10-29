import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/continue_watching.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response, syntheticSession;

void main() {
  test('four themes, lilac default and retired preferences migrate', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(AppAccent.available.map((a) => a.label), [
      '霞光紫',
      '海湾蓝',
      '宝石绿',
      '流金粉',
    ]);
    for (final saved in [
      null,
      'rose',
      'amber',
      'blush',
      'emerald',
      'titanium',
    ]) {
      SharedPreferences.setMockInitialValues({'yingyu.accent.v1': ?saved});
      final store = AppStore(await SharedPreferences.getInstance());
      expect(
        store.accent.name,
        saved == 'rose'
            ? 'blush'
            : [null, 'amber', 'titanium', 'pearl'].contains(saved)
            ? 'lilac'
            : saved,
      );
      store.log.dispose();
      store.dispose();
    }
    expect(appTheme(Brightness.dark).colorScheme.primary, AppAccent.lilac.dark);
  });
  for (final duration in [0, 600]) {
    for (final position in [0, 480]) {
      for (final rewatch in [false, true]) {
        testWidgets(
          'completed shelf bar is full: duration=$duration position=$position rewatch=$rewatch',
          (tester) async {
            SharedPreferences.setMockInitialValues({});
            final store = AppStore(await SharedPreferences.getInstance());
            await store.log.setEnabled(false);
            final api = EmbyClient(
              client: MockClient((_) async => response('{"Items":[]}', 200)),
            )..session = syntheticSession();
            final feed = HomeFeed(api, store);
            feed.resume = [
              MediaItem({
                'Id': 'finished',
                'Name': '合成完成记录',
                'Type': 'Episode',
                'RunTimeTicks': duration * 10000000,
                'UserData': {
                  'Played': true,
                  'PlaybackPositionTicks': position * 10000000,
                },
              }),
            ];
            if (rewatch) {
              await store.saveProgress(
                feed.account,
                'finished',
                const Duration(seconds: 120),
                serverBaseline: feed.resume.single,
              );
            }
            await tester.pumpWidget(
              MaterialApp(
                theme: appTheme(Brightness.dark),
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
            await tester.pump(const Duration(milliseconds: 500));
            final bars = tester.widgetList<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            );
            if ((rewatch || position > 0) && duration == 0) {
              expect(bars, isEmpty);
            } else {
              expect(bars, hasLength(1));
              expect(
                bars.single.value,
                rewatch
                    ? .2
                    : position > 0
                    ? position / duration
                    : 1,
              );
            }
            await tester.pumpWidget(const SizedBox());
            await tester.pump(const Duration(milliseconds: 200));
            feed.dispose();
            api.close();
            store.log.dispose();
            store.dispose();
          },
        );
      }
    }
  }
}
