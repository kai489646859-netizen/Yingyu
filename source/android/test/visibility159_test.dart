// Resume cards follow the server-only display contract introduced in1.7.5.
// Durable local checkpoints and detail history are verified independently.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_order.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/store.dart';
import 'home_history153_test.dart' show undated;
import 'watch_resume131_test.dart' show ep;
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/home_visibility.dart';
import 'package:yingyu/ui/server_visibility.dart';
import 'core_test.dart' show response, syntheticSession;
import 'host/visibility159/old/core/browse_cache.dart' as old;
import 'host/visibility159/old/core/emby.dart' as old_api;
import 'host/visibility159/old/core/home_order.dart' as old_order;
import 'host/visibility159/old/core/models.dart' as old_models;

MediaItem item(String id) => MediaItem({'Id': id, 'Type': 'Movie', 'Name': id});
String page(List<Map<String, dynamic>> items) =>
    jsonEncode({'Items': items, 'TotalRecordCount': items.length});
const publicView = {
  'Id': 'public',
  'Type': 'CollectionFolder',
  'Name': 'Public',
};
const privateView = {
  'Id': 'private',
  'Type': 'CollectionFolder',
  'Name': 'Private',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<Map<String, dynamic>> workflow(bool legacy) async {
    final prefs = await SharedPreferences.getInstance();
    var inventories = 0, views = 0;
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/Views')) {
        views++;
        return response(page([publicView]), 200);
      }
      if (r.url.path.endsWith('/Resume')) {
        return response(page([item('current').data]), 200);
      }
      inventories++;
      return response(page([item('current').data]), 200);
    });
    final dynamic api = legacy
        ? (old_api.EmbyClient(client: client)
            ..session = old_models.Session(
              base: Uri.parse('http://127.0.0.1:9/emby'),
              userId: 'u',
              username: 'u',
              token: 'SYNTHETIC',
              deviceId: 'test',
            ))
        : (EmbyClient(client: client)..session = syntheticSession());
    final dynamic order = legacy
        ? old_order.HomeOrder(prefs)
        : HomeOrder(prefs);
    await order.saveHidden(api.session, <String>{'private'});
    final dynamic repo = legacy
        ? old.BrowseRepository(
            api,
            old.BrowseCache(prefs),
            old.BrowsePreferences(prefs),
            visibility: order,
            spacing: Duration.zero,
          )
        : BrowseRepository(
            api,
            BrowseCache(prefs),
            BrowsePreferences(prefs),
            visibility: order,
            spacing: Duration.zero,
          );
    try {
      await repo.ensureVisibility();
      final dynamic current = await repo.resume(force: true);
      return {
        'inventories': inventories,
        'views': views,
        'visible': (order.visible(api.session, current.items) as List).length,
        'hiddenRetained': (order.hidden(api.session) as Set).contains(
          'private',
        ),
      };
    } finally {
      repo.dispose();
      order.dispose();
      api.close();
    }
  }

  test(
    'complete delivered workflow performs redundant inventory; current skips it',
    () async {
      final baseline = await workflow(true);
      SharedPreferences.setMockInitialValues({});
      final current = await workflow(false);
      expect(baseline['inventories'], greaterThan(0));
      expect(current, {
        'inventories': 0,
        'views': 1,
        'visible': 1,
        'hiddenRetained': true,
      });
    },
  );

  for (final bad in [
    '{}',
    '{"Items":[123]}',
    '{"Items":[{"Id":"a"},{"Id":"a"}]}',
    '{"Items":[{"Id":"a"}],"TotalRecordCount":2}',
  ]) {
    test('malformed or partial Views cannot waive membership: $bad', () async {
      final prefs = await SharedPreferences.getInstance(),
          order = HomeOrder(await SharedPreferences.getInstance());
      final api = EmbyClient(
        client: MockClient((r) async => response(bad, 200)),
      )..session = syntheticSession();
      await order.saveHidden(api.session!, {'private'});
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      await repo.ensureVisibility();
      expect(order.serverScopeKnown(api.session!), false);
      expect(order.ready(api.session!), false);
      expect(order.allows(api.session!, item('old-cache')), false);
      repo.dispose();
      order.dispose();
      api.close();
    });
  }

  test(
    'cached Views cannot grant the shortcut and hidden choices survive restart',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          account = syntheticSession(),
          order = HomeOrder(await SharedPreferences.getInstance());
      var views = 0, inventories = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Views')) {
            views++;
            return response(page([publicView]), 200);
          }
          inventories++;
          return response(page([]), 200);
        }),
      )..session = account;
      await order.saveHidden(account, {'private'});
      final cache = BrowseCache(prefs),
          repo = BrowseRepository(
            api,
            BrowseCache(prefs),
            BrowsePreferences(prefs),
            visibility: order,
            spacing: Duration.zero,
          );
      await cache.put(
        repo.key('views'),
        ItemPage([MediaItem(publicView)], 1),
        DateTime.now(),
      );
      await repo.cache.put(
        repo.key('views'),
        ItemPage([MediaItem(publicView)], 1),
        DateTime.now(),
      );
      await repo.ensureVisibility();
      expect(views, 1);
      expect(inventories, 0);
      expect(order.ready(account), true);
      expect(order.allows(account, item('stale')), false);
      final restored = HomeOrder(prefs);
      expect(restored.hidden(account), {'private'});
      expect(restored.ready(account), false);
      restored.dispose();
      repo.dispose();
      order.dispose();
      api.close();
    },
  );

  test(
    'restored server access reinstates local filtering and full membership resolution',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          order = HomeOrder(await SharedPreferences.getInstance());
      var grant = false, inventories = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Views')) {
            return response(page([publicView, if (grant) privateView]), 200);
          }
          inventories++;
          final id = r.url.queryParameters['ParentId'] == 'private'
              ? 'secret'
              : 'public-movie';
          return response(page([item(id).data]), 200);
        }),
      )..session = syntheticSession();
      final account = api.session!;
      await order.saveHidden(account, {'private'});
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      await repo.ensureVisibility();
      expect(inventories, 0);
      final oldRevision = order.serverRevision(account);
      grant = true;
      await repo.libraries(force: true);
      await repo.ensureVisibility();
      expect(order.serverRevision(account), greaterThan(oldRevision));
      expect(inventories, 2);
      expect(order.ready(account), true);
      expect(order.allows(account, item('secret')), false);
      expect(order.allows(account, item('public-movie')), true);
      repo.dispose();
      order.dispose();
      api.close();
    },
  );

  test(
    'late server item proof cannot cross a permission revision or account',
    () async {
      final order = HomeOrder(await SharedPreferences.getInstance()),
          account = syntheticSession();
      await order.saveHidden(account, {'private'});
      order.observeServerLibraries(account, ['public']);
      final revision = order.serverRevision(account);
      order.observeServerItems(account, [item('a')], revision: revision);
      expect(order.allows(account, item('a')), true);
      order.observeServerLibraries(account, ['different']);
      order.observeServerItems(account, [item('late')], revision: revision);
      expect(order.allows(account, item('a')), false);
      expect(order.allows(account, item('late')), false);
      final other = syntheticSession('http://another.invalid');
      await order.saveHidden(other, {'private'});
      expect(order.ready(other), false);
      order.dispose();
    },
  );

  testWidgets(
    'opened local saved identities use bounded exact IDs and retain inaccessible records',
    (tester) async {
      final order = HomeOrder(await SharedPreferences.getInstance()),
          account = syntheticSession();
      await order.saveHidden(account, {'private'});
      order.observeServerLibraries(account, ['public']);
      final requests = <Uri>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          requests.add(r.url);
          return response(
            page([item('public-movie').data, item('unrequested').data]),
            200,
          );
        }),
      )..session = account;
      final source = ValueNotifier(0);
      final saved = [item('public-movie'), item('private-movie')];
      await tester.pumpWidget(
        MaterialApp(
          home: HomeVisibilityScope(
            order: order,
            child: Scaffold(
              body: ServerVisibilityGate(
                api: api,
                account: account,
                source: source,
                items: () => saved,
                child: Builder(
                  builder: (context) => Text(
                    HomeVisibilityScope.visible(
                      context,
                      account,
                      saved,
                    ).map((i) => i.id).join(','),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(requests.single.queryParameters['Ids']!.split(',').toSet(), {
        'public-movie',
        'private-movie',
      });
      expect(requests.single.queryParameters.containsKey('ParentId'), false);
      expect(find.text('public-movie'), findsOneWidget);
      expect(order.allows(account, item('unrequested')), false);
      expect(saved, hasLength(2));
      source.value++;
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      source.dispose();
      order.dispose();
      api.close();
    },
  );

  test(
    'reauthentication for the same user requires a new live permission snapshot',
    () async {
      final order = HomeOrder(await SharedPreferences.getInstance()),
          first = syntheticSession(),
          second = syntheticSession();
      await order.saveHidden(first, {'private'});
      order.observeServerLibraries(first, ['public']);
      order.observeServerItems(first, [
        item('movie'),
      ], revision: order.serverRevision(first));
      expect(order.allows(first, item('movie')), true);
      expect(order.serverScopeKnown(second), false);
      expect(order.ready(second), false);
      expect(order.allows(second, item('movie')), false);
      order.observeServerLibraries(second, ['public']);
      expect(order.serverHandlesHidden(second), true);
      expect(order.allows(second, item('movie')), false);
      order.dispose();
    },
  );

  test(
    'one locally hidden library still accessible keeps normal membership scan',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          order = HomeOrder(await SharedPreferences.getInstance());
      var inventories = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Views')) {
            return response(page([publicView]), 200);
          }
          inventories++;
          return response(page([item('movie').data]), 200);
        }),
      )..session = syntheticSession();
      await order.saveHidden(api.session!, {'private', 'public'});
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      await repo.ensureVisibility();
      expect(order.serverHandlesHidden(api.session!), false);
      expect(inventories, 1);
      expect(order.allows(api.session!, item('movie')), false);
      repo.dispose();
      order.dispose();
      api.close();
    },
  );

  test(
    'account change during Views cannot establish the old permission shortcut',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          order = HomeOrder(await SharedPreferences.getInstance());
      final entered = Completer<void>(), gate = Completer<void>();
      final api = EmbyClient(
        client: MockClient((r) async {
          entered.complete();
          await gate.future;
          return response(page([publicView]), 200);
        }),
      )..session = syntheticSession();
      final account = api.session!;
      await order.saveHidden(account, {'private'});
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: order,
        spacing: Duration.zero,
      );
      final run = repo.ensureVisibility();
      await entered.future;
      api.session = syntheticSession('http://another.invalid');
      gate.complete();
      await run;
      expect(order.serverScopeKnown(account), false);
      expect(order.ready(account), false);
      repo.dispose();
      order.dispose();
      api.close();
    },
  );

  test(
    'fresh homepage history remains visible without a second catalogue or ID lookup',
    () async {
      final prefs = await SharedPreferences.getInstance(),
          store = AppStore(await SharedPreferences.getInstance());
      final stale = undated(ep(14, seconds: 500)),
          latest = undated(ep(17, seconds: 310));
      var inventories = 0, idQueries = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Views')) {
            return response(page([publicView]), 200);
          }
          if (r.url.path.endsWith('/Resume')) {
            return response(page([stale.data]), 200);
          }
          if (r.url.queryParameters.containsKey('Ids')) {
            idQueries++;
            return response(page([latest.data]), 200);
          }
          if (r.url.queryParameters['SortBy'] == 'DatePlayed') {
            return response(page([latest.data]), 200);
          }
          inventories++;
          return response(page([]), 200);
        }),
      )..session = syntheticSession();
      await store.homeOrder.saveHidden(api.session!, {'private'});
      final repo = BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: store.homeOrder,
        spacing: Duration.zero,
      );
      await repo.ensureVisibility();
      final feed = HomeFeed(api, store, browse: repo);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e14');
      expect(feed.resume.single.resume, const Duration(seconds: 500));
      expect(
        store.homeOrder.visible(api.session!, feed.resume).single.id,
        'e14',
      );
      expect(inventories, 0);
      expect(idQueries, 0);
      feed.dispose();
      repo.dispose();
      api.close();
      store.dispose();
    },
  );

  test(
    'cold restart confirms a pending local resume identity without replacing its position',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final stale = ep(14, seconds: 500, date: '2026-10-20T00:00:00Z');
      final watched = ep(17, seconds: 310, date: '2026-10-19T00:00:00Z');
      var idQueries = 0, inventories = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/Views')) {
            return response(page([publicView]), 200);
          }
          if (r.url.path.endsWith('/e17')) {
            return response(jsonEncode(watched.data), 200);
          }
          if (r.url.queryParameters.containsKey('Ids')) {
            idQueries++;
            return response(page([ep(17, seconds: 9).data]), 200);
          }
          if (r.url.path.endsWith('/Resume') ||
              r.url.queryParameters['SortBy'] == 'DatePlayed') {
            return response(page([stale.data]), 200);
          }
          inventories++;
          return response(page([]), 200);
        }),
      )..session = syntheticSession();
      var store = AppStore(prefs);
      await store.homeOrder.saveHidden(api.session!, {'private'});
      BrowseRepository repository() => BrowseRepository(
        api,
        BrowseCache(prefs),
        BrowsePreferences(prefs),
        visibility: store.homeOrder,
        spacing: Duration.zero,
      );
      var repo = repository();
      await repo.ensureVisibility();
      var feed = HomeFeed(api, store, browse: repo);
      await feed.refreshResume(force: true);
      await feed.afterPlayback(watched, actualCompleted: false);
      expect(feed.resume.single.id, 'e14');
      feed.dispose();
      repo.dispose();
      store.dispose();
      store = AppStore(prefs);
      repo = repository();
      await repo.ensureVisibility();
      feed = HomeFeed(api, store, browse: repo);
      await feed.refreshResume(force: true);
      expect(feed.resume.single.id, 'e14');
      expect(feed.resume.single.resume, const Duration(seconds: 500));
      expect(
        store.homeOrder.visible(api.session!, feed.resume).single.id,
        'e14',
      );
      expect(idQueries, 0);
      expect(inventories, 0);
      feed.dispose();
      repo.dispose();
      api.close();
      store.dispose();
    },
  );
}
