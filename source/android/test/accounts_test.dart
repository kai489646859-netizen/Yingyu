import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise actual failed persistence through the pinned preferences interface.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/account_controller.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/tracks.dart';
import 'core_test.dart' show response;

class FailingAccountPreferences extends InMemorySharedPreferencesStore {
  FailingAccountPreferences(super.data) : super.withData();
  @override
  Future<bool> setValue(String type, String key, Object value) =>
      key == 'flutter.${AccountStore.storageKey}'
      ? Future.value(false)
      : super.setValue(type, key, value);
}

Session accountFixture(
  String id, {
  String server = 'one',
  String name = '同名账号',
  String? token,
}) => Session(
  base: Uri.parse('https://$server.invalid/emby'),
  userId: id,
  username: name,
  token: token ?? 'token-$id',
  deviceId: 'device-$id',
  serverId: server,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppStore store;
  late AccountController controller;
  late EmbyClient transport;
  late Future<http.Response> Function(http.Request) handler;
  late List<http.Request> calls;
  final a = accountFixture('a'), b = accountFixture('b');
  Future<http.Response> valid(http.Request r) async =>
      response(jsonEncode({'Id': r.url.pathSegments.last}), 200);
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AppStore(await SharedPreferences.getInstance());
    calls = [];
    handler = valid;
    transport = EmbyClient(
      client: MockClient((r) {
        calls.add(r);
        return handler(r);
      }),
    );
    controller = AccountController(store, transport);
  });
  tearDown(() {
    controller.dispose();
    transport.close();
    store.dispose();
  });
  Future<void> seed() async {
    await store.saveSession(b);
    await store.saveSession(a);
    await controller.restore();
  }

  test(
    'single account upgrade is durable and leaves progress/cache/preferences intact',
    () async {
      await store.prefs.setString('yingyu.session.v1', a.encode());
      await store.saveProgress(a, 'movie', const Duration(seconds: 80));
      await store.prefs.setString('yingyu.theme.v1', 'light');
      expect((await store.loadSession())!.userId, 'a');
      expect(store.accounts.accounts.length, 1);
      final restarted = AppStore(store.prefs);
      expect((await restarted.loadSession())!.token, a.token);
      expect(restarted.localProgress(a, 'movie'), const Duration(seconds: 80));
      expect(store.prefs.getString('yingyu.theme.v1'), 'light');
      restarted.dispose();
    },
  );

  test(
    'same names and IDs on different servers remain distinct; duplicate login updates token',
    () async {
      final other = accountFixture('a', server: 'two');
      await store.saveSession(a);
      await store.saveSession(b);
      await store.saveSession(other);
      await store.saveSession(accountFixture('a', token: 'renewed-token'));
      expect(store.accounts.accounts.length, 3);
      expect(store.accounts.selected!.session.token, 'renewed-token');
      expect(
        store.accounts.accounts
            .where((e) => e.session.base == other.base)
            .single
            .session
            .token,
        other.token,
      );
    },
  );

  test(
    'switch validates target headers, publishes client atomically, persists last account without logout',
    () async {
      await seed();
      final old = controller.api!;
      final waiting = Completer<http.Response>();
      handler = (_) => waiting.future;
      final switched = controller.switchTo(store.accounts.accounts.first);
      await Future<void>.delayed(Duration.zero);
      expect(controller.api, same(old));
      expect(controller.selected!.id, accountKey(a));
      expect(calls.last.headers['X-Emby-Token'], b.token);
      expect(
        calls.last.headers['X-Emby-Authorization'],
        contains('UserId="b"'),
      );
      waiting.complete(response('{"Id":"b"}', 200));
      await switched;
      expect(controller.api, isNot(same(old)));
      expect(controller.api!.session, same(b));
      expect(old.session!.userId, 'a');
      expect(old.backgroundWork.paused, true);
      expect(calls.any((r) => r.url.path.endsWith('/Logout')), false);
      final restart = AppStore(store.prefs);
      expect((await restart.loadSession())!.userId, 'b');
      restart.dispose();
    },
  );

  for (final status in [401, 403, 500]) {
    test(
      'failed switch HTTP $status retains visible and selected account A',
      () async {
        await seed();
        final old = controller.api;
        handler = (_) async => response('{}', status);
        await expectLater(
          controller.switchTo(controller.accounts.first),
          throwsA(isA<AppFailure>()),
        );
        expect(controller.api, same(old));
        expect(controller.connected, true);
        expect(controller.selected!.id, accountKey(a));
        expect(controller.accounts.first.needsLogin, status == 401);
      },
    );
  }

  test(
    'wrong identity in a successful HTTP response cannot switch accounts',
    () async {
      await seed();
      final old = controller.api;
      handler = (_) async => response('{"Id":"a"}', 200);
      await expectLater(
        controller.switchTo(controller.accounts.first),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.api, same(old));
      expect(controller.selected!.id, accountKey(a));
    },
  );

  test(
    'failed atomic persistence cannot activate B or change the durable last account',
    () async {
      await seed();
      final old = controller.api;
      final original = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = FailingAccountPreferences({
        for (final key in store.prefs.getKeys())
          'flutter.$key': store.prefs.get(key)!,
      });
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      await expectLater(
        controller.switchTo(controller.accounts.first),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.api, same(old));
      expect(controller.selected!.id, accountKey(a));
      await store.prefs.reload();
      final restarted = AppStore(store.prefs);
      expect((await restarted.loadSession())!.userId, 'a');
      restarted.dispose();
    },
  );

  test('rapid repeated clicks cannot start concurrent switches', () async {
    await seed();
    final waiting = Completer<http.Response>();
    handler = (_) => waiting.future;
    final switched = controller.switchTo(controller.accounts.first);
    await expectLater(
      controller.switchTo(controller.accounts.last),
      throwsA(isA<AppFailure>()),
    );
    waiting.complete(response('{"Id":"b"}', 200));
    await switched;
    expect(controller.api!.session!.userId, 'b');
    expect(calls.length, 2);
  });

  test('late 401 from old account never expires the new account', () async {
    await seed();
    final old = controller.api!;
    final waiting = Completer<http.Response>();
    handler = (r) =>
        r.url.path.endsWith('/Items/old') ? waiting.future : valid(r);
    final late = old.detail('old');
    final failure = expectLater(late, throwsA(isA<AppFailure>()));
    await controller.switchTo(controller.accounts.first);
    waiting.complete(response('{}', 401));
    await failure;
    expect(controller.connected, true);
    expect(controller.selected!.id, accountKey(b));
    expect(controller.accounts.first.needsLogin, false);
  });

  test(
    'add failure and mismatched reauthentication preserve every old account',
    () async {
      await seed();
      final old = controller.api;
      handler = (_) async => response('{}', 401);
      await expectLater(
        controller.login('two.invalid', 'new', 'secret'),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.api, same(old));
      expect(controller.accounts.length, 2);
      handler = (_) async => response(
        '{"AccessToken":"new","User":{"Id":"wrong","Name":"wrong"}}',
        200,
      );
      await expectLater(
        controller.login(
          a.base.toString(),
          a.username,
          'secret',
          replacing: controller.accounts.last,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.accounts.length, 2);
      expect(controller.selected!.id, accountKey(a));
    },
  );

  test(
    'adding creates a separate device session and never stores the password',
    () async {
      await seed();
      handler = (_) async => response(
        '{"AccessToken":"token-c","User":{"Id":"c","Name":"C"}}',
        200,
      );
      await controller.login('two.invalid', 'C', 'NEVER_SAVE_PASSWORD');
      expect(controller.accounts.length, 3);
      expect(controller.api!.session!.deviceId, isNot(a.deviceId));
      expect(
        store.prefs.getString(AccountStore.storageKey),
        isNot(contains('NEVER_SAVE_PASSWORD')),
      );
      expect(controller.api!.session!.userId, 'c');
    },
  );

  test(
    'removing current account does not silently select another or delete progress',
    () async {
      await seed();
      await store.saveProgress(a, 'same-id', const Duration(seconds: 91));
      await controller.remove(controller.accounts.last);
      expect(controller.connected, false);
      expect(controller.api, isNull);
      expect(store.accounts.selected, isNull);
      expect(controller.accounts.single.id, accountKey(b));
      expect(store.localProgress(a, 'same-id')!.inSeconds, 91);
      expect(await AppStore(store.prefs).loadSession(), isNull);
    },
  );

  test(
    'logout retires A while validating B, then persists B without crossing progress or credentials',
    () async {
      await seed();
      final old = controller.api!;
      await store.saveProgress(a, 'same-id', const Duration(seconds: 91));
      await store.saveProgress(b, 'same-id', const Duration(seconds: 182));
      final waiting = Completer<http.Response>();
      handler = (r) =>
          r.url.path.endsWith('/Users/b') ? waiting.future : valid(r);
      final removal = controller.remove(
        controller.selected!,
        switchToRemaining: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.connected, false);
      expect(controller.api, isNull);
      expect(controller.busy, true);
      expect(controller.selected, isNull);
      expect(old.backgroundWork.paused, true);
      final check = calls.singleWhere((r) => r.url.path.endsWith('/Users/b'));
      expect(check.headers['X-Emby-Token'], b.token);
      waiting.complete(response('{"Id":"b"}', 200));
      await removal;
      expect(controller.connected, true);
      expect(controller.api!.session, same(b));
      expect(controller.accounts.map((e) => e.id), [accountKey(b)]);
      expect(store.localProgress(a, 'same-id')!.inSeconds, 91);
      expect(store.localProgress(b, 'same-id')!.inSeconds, 182);
      final logout = calls.where((r) => r.url.path.endsWith('/Logout')).single;
      expect(logout.headers['X-Emby-Token'], a.token);
      final restarted = AppStore(store.prefs);
      expect((await restarted.loadSession())!.userId, b.userId);
      restarted.dispose();
    },
  );

  test('logout of the last account leaves a clean login state', () async {
    await store.saveSession(a);
    await controller.restore();
    await controller.remove(controller.selected!, switchToRemaining: true);
    expect(controller.connected, false);
    expect(controller.api, isNull);
    expect(controller.accounts, isEmpty);
    expect(controller.selected, isNull);
    expect(controller.error, isNull);
  });

  test(
    'logout skips known expired accounts and handles a newly expired candidate before entering C',
    () async {
      final c = accountFixture('c'), expired = accountFixture('expired');
      await store.saveSession(expired);
      await store.accounts.expire(accountKey(expired));
      await store.saveSession(b);
      await store.saveSession(c);
      await store.saveSession(a);
      await controller.restore();
      handler = (r) async =>
          r.url.path.endsWith('/Users/b') ? response('{}', 401) : valid(r);
      await controller.remove(controller.selected!, switchToRemaining: true);
      expect(controller.api!.session!.userId, c.userId);
      expect(
        controller.accounts
            .where((e) => e.id == accountKey(b))
            .single
            .needsLogin,
        true,
      );
      expect(calls.any((r) => r.url.path.endsWith('/Users/expired')), false);
      expect(calls.where((r) => r.url.path.endsWith('/Logout')).length, 1);
      expect(controller.error, isNull);
    },
  );

  for (final status in [401, 403, 500]) {
    test(
      'failed automatic switch HTTP $status leaves A logged out and B intact with an error',
      () async {
        await seed();
        handler = (r) async =>
            r.url.path.endsWith('/Users/b') ? response('{}', status) : valid(r);
        await controller.remove(controller.selected!, switchToRemaining: true);
        expect(controller.connected, false);
        expect(controller.api, isNull);
        expect(controller.selected, isNull);
        expect(controller.accounts.single.id, accountKey(b));
        expect(controller.accounts.single.needsLogin, status == 401);
        expect(controller.error, contains('自动切换未完成'));
      },
    );
  }

  test(
    'failed logout persistence retains A and makes no logout or automatic switch request',
    () async {
      await seed();
      final old = controller.api;
      final original = SharedPreferencesStorePlatform.instance;
      SharedPreferencesStorePlatform.instance = FailingAccountPreferences({
        for (final key in store.prefs.getKeys())
          'flutter.$key': store.prefs.get(key)!,
      });
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      await expectLater(
        controller.remove(controller.selected!, switchToRemaining: true),
        throwsA(isA<AppFailure>()),
      );
      expect(controller.api, same(old));
      expect(controller.selected!.id, accountKey(a));
      expect(calls.length, 1);
    },
  );

  test(
    'server logout failure stays visible even when B is entered successfully',
    () async {
      await seed();
      handler = (r) async =>
          r.url.path.endsWith('/Logout') ? response('{}', 500) : valid(r);
      await controller.remove(controller.selected!, switchToRemaining: true);
      expect(controller.api!.session, same(b));
      expect(controller.connected, true);
      expect(controller.error, contains('服务器注销未完成'));
    },
  );

  test(
    'overlapping item IDs never share progress, track choices, or catalogue data',
    () async {
      final c = accountFixture('a', server: 'two');
      for (final entry in [a, b, c].indexed) {
        await store.saveProgress(
          entry.$2,
          'same',
          Duration(seconds: entry.$1 + 10),
        );
        await store.saveTrackChoice(
          entry.$2,
          ['item:same'],
          true,
          TrackChoice({'id': '${entry.$1}'}),
        );
        final api = transport.forAccount(entry.$2);
        final prefs = BrowsePreferences(store.prefs);
        final browse = BrowseRepository(
          api,
          store.browseCache,
          prefs,
          spacing: Duration.zero,
        );
        await store.browseCache.put(
          browse.key('same'),
          ItemPage([
            MediaItem({
              'Id': 'same',
              'Name': 'account-${entry.$1}',
              'UserData': {'Played': entry.$1 == 1},
            }),
          ], 1),
          DateTime.now(),
        );
        browse.dispose();
        prefs.dispose();
      }
      for (final entry in [a, b, c].indexed) {
        expect(store.localProgress(entry.$2, 'same')!.inSeconds, entry.$1 + 10);
        expect(
          store.trackChoice(entry.$2, 'item:same', true)!.data['id'],
          '${entry.$1}',
        );
        final browse = BrowseCache(store.prefs);
        final key = jsonEncode([
          entry.$2.base.toString(),
          entry.$2.userId,
          'same',
        ]);
        expect(browse.get(key)!.items.single.title, 'account-${entry.$1}');
      }
    },
  );
}
