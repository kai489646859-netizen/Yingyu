import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/federated_search_page.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'offline_settle.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/federated_search.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/person_name_index.dart';
import 'core_test.dart' show response;

Session source(int n, {String? user}) => Session(
  base: Uri.parse('https://server$n.invalid/emby'),
  userId: user ?? 'user$n',
  token: 'TOKEN_${user ?? n}',
  username: user ?? 'account$n',
  deviceId: 'fixture',
);
MediaItem actor(String id, String name) =>
    MediaItem({'Id': id, 'Name': name, 'Type': 'Person'});
void main() {
  test(
    'actor direct match finishes without waiting for an unrelated full directory',
    () async {
      var directoryReads = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          if (!r.url.queryParameters.containsKey('SearchTerm') &&
              !r.url.queryParameters.containsKey('NameStartsWith')) {
            directoryReads++;
            return Completer<Never>().future;
          }
          return response(
            jsonEncode({
              'Items': [
                {'Id': 'zhou', 'Name': '周星驰', 'Type': 'Person'},
              ],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }),
      )..session = source(1);
      final result = await api
          .searchPeople('周星驰')
          .timeout(const Duration(milliseconds: 300));
      expect(result.items.single.title, '周星驰');
      expect(directoryReads, 0);
      api.close();
    },
  );
  test(
    'progressive fragment search stops at first useful page and resumes its directory cursor',
    () async {
      final index = PersonNameIndex();
      final offsets = <int>[];
      Future<ItemPage> fetch(int start) async {
        offsets.add(start);
        return ItemPage([actor('p$start', start == 0 ? '周星驰' : '周迅')], 2);
      }

      final first = await index.search(
        '周',
        direct: () async => ItemPage([], 0),
        fetch: fetch,
        allowed: () => true,
        progressive: true,
      );
      expect(first.items.single.id, 'p0');
      expect(first.total, 2);
      expect(offsets, [0]);
      final next = await index.search(
        '周',
        start: 1,
        direct: () async => ItemPage([], 0),
        fetch: fetch,
        allowed: () => true,
        progressive: true,
      );
      expect(next.items.single.id, 'p1');
      expect(offsets, [0, 1]);
    },
  );
  test(
    'new alphabetically earlier matches do not reorder delivered progressive pages',
    () async {
      final index = PersonNameIndex();
      final first = await index.search(
        '周',
        progressive: true,
        direct: () async => ItemPage([actor('z', '周星驰')], 1),
        fetch: (_) async => throw StateError('no scan yet'),
        allowed: () => true,
      );
      expect(first.items.single.id, 'z');
      final next = await index.search(
        '周',
        start: 1,
        progressive: true,
        direct: () async => ItemPage([actor('a', '周一')], 1),
        fetch: (_) async => throw StateError('no scan needed'),
        allowed: () => true,
      );
      expect(next.items.single.id, 'a');
    },
  );
  test(
    'federated results retain source credentials even with same server and same item IDs',
    () async {
      final seen = <String>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          seen.add('${r.url.host}:${r.url.path}:${r.headers['X-Emby-Token']}');
          return response(
            jsonEncode({
              'Items': [
                {
                  'Id': 'same',
                  'Name': r.url.queryParameters['SearchTerm'],
                  'Type': 'Movie',
                },
              ],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }),
      )..session = source(1);
      final coordinator = FederatedSearch(api, [
        SavedAccount(source(1)),
        SavedAccount(source(2)),
        SavedAccount(source(1, user: 'second')),
      ]);
      await coordinator.search('独有影片');
      expect(coordinator.sources.map((s) => s.items.single.id), [
        'same',
        'same',
        'same',
      ]);
      expect(coordinator.sources.map((s) => s.account.id).toSet().length, 3);
      expect(seen.any((s) => s.contains('/Users/second/Items')), true);
      expect(seen.any((s) => s.endsWith('TOKEN_second')), true);
      expect(api.session!.userId, 'user1');
      coordinator.dispose();
      await api.items(search: 'still live');
      expect(seen.length, 16);
      api.close();
    },
  );
  test(
    'fast server becomes visible before slow server; failures preserve other results',
    () async {
      final gate = Completer<void>();
      final api = EmbyClient(
        client: MockClient((r) async {
          if (r.url.host == 'server2.invalid') {
            await gate.future;
            return response('{}', 503);
          }
          return response(
            '{"Items":[{"Id":"onlyA","Name":"A独有","Type":"Movie"}],"TotalRecordCount":1}',
            200,
          );
        }),
      );
      final c = FederatedSearch(api, [
        SavedAccount(source(1)),
        SavedAccount(source(2)),
      ]);
      final search = c.search('影片');
      for (var n = 0; n < 50 && c.sources.first.items.isEmpty; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(c.sources.first.items.single.id, 'onlyA');
      expect(c.sources.last.busy, true);
      gate.complete();
      await search;
      expect(c.sources.last.error, isNotNull);
      expect(c.sources.first.error, isNull);
      c.dispose();
      api.close();
    },
  );
  test(
    'initial fanout is at most three accounts and expires no unrelated account',
    () async {
      var active = 0, peak = 0, calls = 0;
      final gates = <Completer<void>>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          active++;
          if (active > peak) peak = active;
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          active--;
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      );
      final c = FederatedSearch(api, [
        for (var n = 1; n <= 5; n++) SavedAccount(source(n)),
        SavedAccount(source(6), needsLogin: true),
      ]);
      final job = c.search('电影');
      while (gates.length < 3) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(calls, 3);
      var completed = false;
      job.whenComplete(() => completed = true);
      while (!completed) {
        for (final gate in List<Completer<void>>.of(gates)) {
          if (!gate.isCompleted) gate.complete();
        }
        await Future<void>.delayed(Duration.zero);
      }
      await job;
      expect(peak, 3);
      expect(calls, 15);
      expect(c.sources.last.error, '需要重新登录');
      c.dispose();
      api.close();
    },
  );
  test(
    'new query invalidates late results and empty query makes no request',
    () async {
      final old = Completer<void>();
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          final term = r.url.queryParameters['SearchTerm'];
          if (term == 'old') await old.future;
          return response(
            jsonEncode({
              'Items': [
                {'Id': term, 'Name': term, 'Type': 'Movie'},
              ],
              'TotalRecordCount': 1,
            }),
            200,
          );
        }),
      );
      final c = FederatedSearch(api, [SavedAccount(source(1))]);
      await c.search('');
      expect(calls, 0);
      final previous = c.search('old');
      while (calls == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await c.search('new');
      old.complete();
      await previous;
      expect(c.sources.single.items.first.id, 'new');
      expect(c.sources.single.items.map((i) => i.id).toSet(), {
        'new',
        'n',
        'e',
        'w',
      });
      c.dispose();
      api.close();
    },
  );
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets(
      'aggregate sources render and open the selected source at $size',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final pause = Object();
        PosterDemand.pause(pause, true);
        final store = AppStore(await SharedPreferences.getInstance());
        await store.log.setEnabled(false);
        await store.accounts.load(store.deviceId);
        await store.accounts.saveAndSelect(source(1));
        await store.accounts.saveAndSelect(source(2));
        final api = EmbyClient(
          client: MockClient(
            (r) async => response(
              jsonEncode({
                'Items': [
                  {
                    'Id': 'same',
                    'Name': r.url.host == 'server1.invalid' ? 'A独有' : 'B独有',
                    'Type': 'Movie',
                  },
                ],
                'TotalRecordCount': 1,
              }),
              200,
            ),
          ),
        )..session = source(1);
        String? opened;
        final preview = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: preview,
            child: MaterialApp(
              home: FederatedSearchPage(
                api: api,
                store: store,
                initialQuery: '影片',
                onOpen: (account, item) async {
                  opened = '${account.session.userId}:${item.title}';
                },
              ),
            ),
          ),
        );
        await settleOffline(tester);
        await tester.pumpAndSettle();
        expect(find.text('A独有'), findsOneWidget);
        expect(find.text('B独有'), findsOneWidget);
        await tester.runAsync(() async {
          final image =
              await (preview.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'build/search183/aggregate-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.ensureVisible(find.text('B独有'));
        await tester.tap(find.text('B独有'));
        await tester.pump();
        expect(opened, 'user2:B独有');
        expect(api.session!.userId, 'user1');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await settleOffline(tester);
        api.close();
        store.log.dispose();
        store.dispose();
        PosterDemand.pause(pause, false);
      },
    );
  }
}
