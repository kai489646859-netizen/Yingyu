import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/library_events.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'core_test.dart' show response, syntheticSession;

class Wire {
  final input = StreamController<dynamic>();
  final sent = <String>[];
  int closes = 0;
  LibraryEventChannel get channel =>
      LibraryEventChannel(input.stream, sent.add, () async {
        closes++;
        await input.close();
      });
  void change({
    List<String> removed = const [],
    List<String> added = const [],
  }) => input.add(
    jsonEncode({
      'MessageType': 'LibraryChanged',
      'Data': {'ItemsRemoved': removed, 'ItemsAdded': added},
    }),
  );
}

class LoopbackHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<void> settle(LibraryEvents events) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await events.settled;
  }

  test(
    'push removal cleans current caches, descendants and discovery without HTTP',
    () async {
      var calls = 0;
      final prefs = await SharedPreferences.getInstance();
      final api = EmbyClient(
        client: MockClient((_) async {
          calls++;
          return response('{}', 500);
        }),
      )..session = syntheticSession();
      final store = AppStore(prefs);
      final account = api.session!;
      final browse = BrowseRepository(
        api,
        store.browseCache,
        BrowsePreferences(prefs),
        visibility: store.homeOrder,
      );
      final items = [
        MediaItem({'Id': 'series', 'Type': 'Series'}),
        MediaItem({'Id': 'episode', 'Type': 'Episode', 'SeriesId': 'series'}),
        MediaItem({'Id': 'keep', 'Type': 'Movie'}),
      ];
      await browse.cache.put(
        browse.key('resume:0:18'),
        ItemPage(items, 3),
        DateTime.now(),
      );
      final otherKey = jsonEncode([
        account.base.toString(),
        'other-user',
        'catalog',
      ]);
      await browse.cache.put(otherKey, ItemPage(items, 3), DateTime.now());
      final feed = HomeFeed(api, store, browse: browse);
      final wire = Wire();
      final events = LibraryEvents(
        api,
        connect: (_) async => wire.channel,
        coalesce: Duration.zero,
        onChanges: (removed, added) async {
          await browse.acceptLibraryChanges(removed, added);
          await feed.acceptRemovals(removed);
        },
      );
      addTearDown(() {
        events.dispose();
        feed.dispose();
        browse.dispose();
        api.close();
      });
      events.setActive(true);
      await settle(events);
      wire.change(removed: ['series']);
      await settle(events);
      expect(calls, 0);
      expect(browse.peek('resume:0:18')!.items.map((i) => i.id), ['keep']);
      expect(browse.cache.get(otherKey)!.items, hasLength(3));
      expect(feed.resume.map((i) => i.id), ['keep']);
      expect(store.homeOrder.visible(account, items).map((i) => i.id), [
        'keep',
      ]);
      final reopened = HomeOrder(prefs);
      expect(reopened.visible(account, items).map((i) => i.id), ['keep']);
      expect(
        BrowseCache(
          prefs,
        ).get(browse.key('resume:0:18'))!.items.map((i) => i.id),
        ['keep'],
      );
      // New notification for the same real ID restores eligibility, not old rows.
      wire.change(added: ['series']);
      await settle(events);
      expect(reopened.visible(account, items), hasLength(1));
      expect(store.homeOrder.visible(account, items), hasLength(3));
      expect(browse.peek('resume:0:18')!.items, hasLength(1));
      expect(calls, 0);
      reopened.dispose();
    },
  );
  test('invalid payloads and remote commands never mutate library', () async {
    final api = EmbyClient(client: MockClient((_) async => response('{}', 500)))
      ..session = syntheticSession();
    final wire = Wire();
    final changes = <Set<String>>[];
    final events = LibraryEvents(
      api,
      connect: (_) async => wire.channel,
      coalesce: Duration.zero,
      onChanges: (removed, added) async => changes.add(removed),
    );
    addTearDown(() {
      events.dispose();
      api.close();
    });
    events.setActive(true);
    await settle(events);
    for (final value in [
      '{',
      jsonEncode({
        'MessageType': 'Play',
        'Data': {
          'ItemIds': ['gone'],
        },
      }),
      jsonEncode({
        'MessageType': 'LibraryChanged',
        'Data': {
          'ItemsRemoved': [12],
        },
      }),
      jsonEncode({
        'MessageType': 'LibraryChanged',
        'Data': {
          'ItemsRemoved': ['gone'],
          'ItemsAdded': {},
        },
      }),
      List<int>.filled(10, 0),
    ]) {
      wire.input.add(value);
    }
    wire.input.add('{"MessageType":"ForceKeepAlive"}');
    await settle(events);
    expect(changes, isEmpty);
    expect(wire.sent, ['{"MessageType":"KeepAlive"}']);
  });
  test(
    'coalesced events preserve last operation and old account is ignored',
    () async {
      final api = EmbyClient(
        client: MockClient((_) async => response('{}', 500)),
      )..session = syntheticSession();
      final wire = Wire();
      final changes = <(Set<String>, Set<String>)>[];
      final events = LibraryEvents(
        api,
        connect: (_) async => wire.channel,
        coalesce: const Duration(milliseconds: 5),
        onChanges: (r, a) async => changes.add((r, a)),
      );
      addTearDown(() {
        events.dispose();
        api.close();
      });
      events.setActive(true);
      await settle(events);
      wire.change(removed: ['a']);
      wire.change(added: ['a']);
      wire.change(removed: ['b']);
      await settle(events);
      expect(changes, hasLength(1));
      expect(changes.single.$1, {'b'});
      expect(changes.single.$2, {'a'});
      api.session = syntheticSession();
      wire.change(removed: ['new-account-item']);
      await settle(events);
      expect(changes, hasLength(1));
    },
  );
  test(
    'disconnect uses backoff, pause stops retry, resume respects cooldown',
    () async {
      final api = EmbyClient(
        client: MockClient((_) async => response('{}', 500)),
      )..session = syntheticSession();
      var attempts = 0;
      final events = LibraryEvents(
        api,
        connect: (_) async {
          attempts++;
          throw const SocketException('synthetic');
        },
        retryBase: const Duration(milliseconds: 100),
        onChanges: (r, a) async {},
      );
      addTearDown(() {
        events.dispose();
        api.close();
      });
      events.setActive(true);
      await settle(events);
      expect(attempts, 1);
      events.setActive(false);
      await Future<void>.delayed(const Duration(milliseconds: 110));
      expect(attempts, 1);
      events.setActive(true);
      await settle(events);
      expect(attempts, 2);
      events.setActive(false);
      events.setActive(true);
      await settle(events);
      expect(attempts, 2);
    },
  );
  test(
    'late connection closes after suspend and does not deliver events',
    () async {
      final api = EmbyClient(
        client: MockClient((_) async => response('{}', 500)),
      )..session = syntheticSession();
      final result = Completer<LibraryEventChannel>();
      var closed = 0, changes = 0;
      final events = LibraryEvents(
        api,
        connect: (_) => result.future,
        onChanges: (r, a) async {
          changes++;
        },
      );
      addTearDown(() {
        events.dispose();
        api.close();
      });
      events.setActive(true);
      events.setActive(false);
      result.complete(
        LibraryEventChannel(const Stream.empty(), (_) {}, () async {
          closed++;
        }),
      );
      await settle(events);
      expect(closed, 1);
      expect(events.connected, false);
      expect(changes, 0);
    },
  );
  test('event URI retains proxy path, IPv6 and device identity', () {
    final original = syntheticSession();
    final uri = libraryEventUri(original);
    expect(uri.scheme, 'ws');
    expect(uri.path, '/proxy/embywebsocket');
    expect(uri.queryParameters['api_key'], original.token);
    expect(uri.queryParameters['deviceId'], original.deviceId);
    final ipv6 = Session(
      base: Uri.parse('https://[::1]:8920/media/emby'),
      userId: original.userId,
      token: original.token,
      deviceId: original.deviceId,
      username: original.username,
    );
    expect(libraryEventUri(ipv6).scheme, 'wss');
    expect(libraryEventUri(ipv6).host, '::1');
    expect(libraryEventUri(ipv6).path, '/media/embywebsocket');
  });
  test(
    'an HTTP snapshot started before removal cannot repopulate the cache',
    () async {
      final api = EmbyClient(
        client: MockClient((_) async => response('{}', 500)),
      )..session = syntheticSession();
      final prefs = await SharedPreferences.getInstance();
      final order = HomeOrder(prefs);
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      final removed = MediaItem({'Id': 'removed', 'Type': 'Movie'});
      final kept = MediaItem({'Id': 'kept', 'Type': 'Movie'});
      await repo.cache.put(
        repo.key('old-page'),
        ItemPage([removed, kept], 2),
        DateTime.now(),
      );
      final pending = Completer<ItemPage>();
      final started = Completer<void>();
      final task = repo.read('old-page', () {
        started.complete();
        return pending.future;
      }, force: true);
      final assertion = expectLater(task, throwsA(isA<AppFailure>()));
      await started.future;
      final notification = repo.acceptLibraryChanges({'removed'}, {});
      pending.complete(ItemPage([removed, kept], 2));
      await notification;
      await assertion;
      expect(repo.peek('old-page')!.items.map((i) => i.id), ['kept']);
      expect(order.allows(api.session!, removed), false);
      // A later real response recovers a re-added item whose push was missed
      // while offline. The stale response above must not do so.
      await repo.read(
        'old-page',
        () async => ItemPage([removed, kept], 2),
        force: true,
      );
      expect(order.allows(api.session!, removed), true);
      expect(HomeOrder(prefs).allows(api.session!, removed), true);
      repo.dispose();
      order.dispose();
      api.close();
    },
  );
  test(
    'synthetic socket upgrade receives notification and closes cleanly',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final original = syntheticSession();
      final account = Session(
        base: Uri.parse('http://127.0.0.1:${server.port}/proxy/emby'),
        userId: original.userId,
        token: original.token,
        deviceId: original.deviceId,
        username: original.username,
      );
      WebSocket? peer;
      final accept = server.listen((request) async {
        expect(request.uri.path, '/proxy/embywebsocket');
        peer = await WebSocketTransformer.upgrade(request);
        peer!.add(
          '{"MessageType":"LibraryChanged","Data":{"ItemsRemoved":["gone"]}}',
        );
      });
      addTearDown(() async {
        await peer?.close();
        await accept.cancel();
        await server.close(force: true);
      });
      final channel = await HttpOverrides.runWithHttpOverrides(
        () => connectLibraryEvents(account),
        LoopbackHttp(),
      );
      final received = await channel.messages.first.timeout(
        const Duration(seconds: 2),
      );
      expect(jsonDecode(received)['Data']['ItemsRemoved'], ['gone']);
      await channel.close();
    },
  );
  test('socket upgrade never follows redirect carrying token', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    final accept = server.listen((request) async {
      requests++;
      request.response.statusCode = 302;
      request.response.headers.set('Location', '/redirect-target');
      await request.response.close();
    });
    addTearDown(() async {
      await accept.cancel();
      await server.close(force: true);
    });
    final original = syntheticSession();
    final account = Session(
      base: Uri.parse('http://127.0.0.1:${server.port}/emby'),
      userId: original.userId,
      token: original.token,
      deviceId: original.deviceId,
      username: original.username,
    );
    await expectLater(
      HttpOverrides.runWithHttpOverrides(
        () => connectLibraryEvents(account),
        LoopbackHttp(),
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(requests, 1);
  });
}
