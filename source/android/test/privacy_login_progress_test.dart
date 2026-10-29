// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/server_address.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/core/version_groups.dart';
import 'package:yingyu/ui/login.dart';
import 'package:yingyu/ui/settings_choice.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/watch_progress.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  MediaItem movie(String id) =>
      MediaItem({'Id': id, 'Name': '合成影片 $id', 'Type': 'Movie'});
  for (final entry in {
    '192.168.1.10': 'http://192.168.1.10:8096/emby',
    '192.168.1.10:8097': 'http://192.168.1.10:8097/emby',
    'http://192.168.1.10:8096': 'http://192.168.1.10:8096/emby',
    'https://media.example/proxy': 'https://media.example/proxy/emby',
    '[fd00::123]:8096': 'http://[fd00::123]:8096/emby',
  }.entries) {
    test(
      'server parser preserves LAN, IPv6 and reverse proxy ${entry.key}',
      () {
        expect(ServerAddress.parse(entry.key).address, entry.value);
      },
    );
  }
  test(
    'invalid schemes, credentials, query and ports never become login targets',
    () {
      for (final value in [
        'ftp://media.example',
        'http://user:secret@media.example',
        'https://host/?api_key=secret',
        'http://host:65536',
      ]) {
        expect(() => ServerAddress.parse(value), throwsA(isA<AppFailure>()));
      }
      expect(
        () => const ServerAddress('http', 'host', '0', '').address,
        throwsA(isA<AppFailure>()),
      );
    },
  );
  testWidgets(
    'historical played flag preserves server position and local replay checkpoint',
    (tester) async {
      final store = AppStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      final account = syntheticSession();
      final item = MediaItem({
        ...movie('a').data,
        'RunTimeTicks': ticks(const Duration(minutes: 10)),
        'UserData': {
          'Played': true,
          'PlaybackPositionTicks': ticks(const Duration(minutes: 8)),
        },
      });
      Future<void> mount() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WatchProgress(item: item, account: account, store: store),
            ),
          ),
        );
      }

      await mount();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .8,
      );
      expect(find.textContaining('重看至'), findsOneWidget);
      await store.saveProgress(
        account,
        item.id,
        const Duration(minutes: 2),
        serverBaseline: item,
      );
      await tester.pumpWidget(const SizedBox());
      await mount();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .2,
      );
      expect(find.textContaining('重看至'), findsOneWidget);
      final acknowledged = MediaItem({
        ...item.data,
        'UserData': {
          ...object(item.data['UserData']),
          'PlaybackPositionTicks': ticks(const Duration(minutes: 2)),
          'LastPlayedDate': '2026-10-11T10:00:00Z',
        },
      });
      await store.recordWatchDisplay(
        account,
        item,
        const Duration(minutes: 2),
        true,
      );
      await store.observeProgress(
        account,
        acknowledged,
        const Duration(minutes: 2),
      );
      await store.confirmProgress(account, item.id, const Duration(minutes: 2));
      expect(store.localProgress(account, item.id), isNull);
      expect(store.rewatchObserved(account, acknowledged), true);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WatchProgress(
              item: acknowledged,
              account: account,
              store: store,
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        .2,
      );
      final completedElsewhere = MediaItem({
        ...acknowledged.data,
        'UserData': {
          ...object(acknowledged.data['UserData']),
          'LastPlayedDate': '2026-10-11T12:00:00Z',
        },
      });
      expect(store.rewatchObserved(account, completedElsewhere), false);
    },
  );
  test(
    'acknowledged rewatch survives home reopening until actual completion',
    () async {
      final store = AppStore(await SharedPreferences.getInstance());
      var detail = MediaItem({
        'Id': 'rewatched',
        'Type': 'Movie',
        'Name': '合成重看影片',
        'RunTimeTicks': ticks(const Duration(minutes: 10)),
        'UserData': {
          'Played': true,
          'PlaybackPositionTicks': ticks(const Duration(minutes: 2)),
          'LastPlayedDate': '2026-10-11T10:00:00Z',
        },
      });
      final api = EmbyClient(
        client: MockClient(
          (request) async => response(
            jsonEncode(
              request.url.path.endsWith('/Resume')
                  ? {'Items': <Json>[]}
                  : detail.data,
            ),
            200,
          ),
        ),
      )..session = syntheticSession();
      final feed = HomeFeed(api, store);
      await feed.afterPlayback(detail, actualCompleted: false);
      expect(feed.resume, isEmpty);
      expect(store.rewatchObserved(api.session!, detail), true);
      final reopened = HomeFeed(api, store);
      expect(reopened.resume, isEmpty);
      expect(reopened.cachedItems.single.resume, const Duration(minutes: 2));
      detail = MediaItem({
        ...detail.data,
        'UserData': {
          'Played': true,
          'PlaybackPositionTicks': 0,
          'LastPlayedDate': '2026-10-11T10:10:00Z',
        },
      });
      await reopened.afterPlayback(detail, actualCompleted: true);
      await reopened.refreshResume(force: true);
      expect(reopened.resume, isEmpty);
      expect(store.rewatchObserved(api.session!, detail), false);
      final completed = HomeFeed(api, store);
      expect(completed.resume, isEmpty);
      expect(
        object(completed.cachedItems.single.data['UserData'])['Played'],
        true,
      );
      completed.dispose();
      reopened.dispose();
      feed.dispose();
      store.dispose();
    },
  );
  testWidgets('LAN login sends separated values without a smart paste entry', (
    tester,
  ) async {
    String? address, user, secret;
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: LoginPage(
          login: (a, u, p) async {
            calls++;
            address = a;
            user = u;
            secret = p;
          },
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('account-server')),
      '192.168.1.8',
    );
    await tester.enterText(find.byKey(const Key('server-port')), '8096');
    await tester.ensureVisible(find.byKey(const Key('account-username')));
    await tester.enterText(find.byKey(const Key('account-username')), '测试');
    await tester.ensureVisible(find.byKey(const Key('account-password')));
    await tester.enterText(find.byKey(const Key('account-password')), '合成口令');
    expect(find.byKey(const Key('smart-paste-expand')), findsNothing);
    expect(calls, 0);
    await tester.ensureVisible(find.byKey(const Key('account-login-submit')));
    await tester.tap(find.byKey(const Key('account-login-submit')));
    await tester.pumpAndSettle();
    expect(
      [address, user, secret],
      ['http://192.168.1.8:8096/emby', '测试', '合成口令'],
    );
    expect(calls, 1);
    // A scheme-less pasted host must keep the separately chosen protocol
    // and port. A full URL, in contrast, supplies its own protocol and port.
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          key: UniqueKey(),
          initialServer: 'https://old.invalid:8920',
          initialUsername: '测试',
          login: (a, u, p) async {
            address = a;
          },
        ),
      ),
    );
    for (final entry in {
      '[fd00::8]:8097': 'https://[fd00::8]:8097/emby',
      '192.168.1.8/proxy': 'https://192.168.1.8:8097/proxy/emby',
      'http://192.168.1.8:8096': 'http://192.168.1.8:8096/emby',
    }.entries) {
      await tester.ensureVisible(find.byKey(const Key('account-server')));
      await tester.enterText(
        find.byKey(const Key('account-server')),
        entry.key,
      );
      await tester.ensureVisible(find.byKey(const Key('account-login-submit')));
      await tester.tap(find.byKey(const Key('account-login-submit')));
      await tester.pumpAndSettle();
      expect(address, entry.value);
    }
  });
  testWidgets(
    'whole settings row opens one arrow-anchored menu with an animated chevron',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsChoice<int>(
              id: 'choice',
              title: '选择项',
              subtitle: '说明',
              value: 1,
              choices: const {1: '一', 2: '二'},
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('选择项'));
      await tester.pumpAndSettle();
      expect(find.text('二'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('说明'));
      await tester.pumpAndSettle();
      expect(find.text('二'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('choice-arrow')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final rotation = tester.widget<RotationTransition>(
        find.byType(RotationTransition).first,
      );
      expect(rotation.turns.value, greaterThan(0));
      expect(rotation.turns.value, lessThan(.25));
      await tester.pumpAndSettle();
      expect(find.text('二'), findsOneWidget);
    },
  );
  test(
    'media source description identifies technical variants without joining their identity',
    () {
      expect(
        sourceDescription({
          'Id': '4k',
          'Name': '导演剪辑版',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Width': 3840,
              'Height': 2160,
              'Codec': 'hevc',
              'VideoRangeType': 'DOVI',
              'BitRate': 50000000,
            },
          ],
        }),
        allOf(
          contains('4K'),
          contains('杜比视界'),
          contains('50.0 Mbps'),
          contains('导演剪辑版'),
        ),
      );
    },
  );
}
