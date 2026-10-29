import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/broad_search.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/catalog_filters.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/federated_search.dart';
import 'package:yingyu/core/accounts.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem actor(String id, String name) =>
    MediaItem({'Id': id, 'Name': name, 'Type': 'Person'});
void main() {
  for (final (query, title) in [
    ('周驰', '周星驰'),
    ('驰周', '周星驰'),
    ('周刘', '周星驰'),
    ('周刘', '刘德华'),
    ('星', '周星驰'),
    ('周 周', '周星驰'),
    (' ＪＯＨＮ・ＳＭＩＴＨ ', 'John Smith'),
    ('流地', '流浪地球2'),
    ('地2', '流浪地球2'),
    ('𠮷野', '𠮷野裕行'),
  ]) {
    test(
      'literal character match $query / $title',
      () => expect(SearchMatch(query).accepts(title), true),
    );
  }
  test(
    'no shared letter is rejected and rank favors exact, continuous, gaps then partial',
    () {
      final match = SearchMatch('周驰');
      expect(match.accepts('刘德华'), false);
      expect(
        ['周迅', '驰周', '周星驰', '周驰传', '周驰']
          ..sort((a, b) => match.score(a).compareTo(match.score(b))),
        ['周驰', '周驰传', '周星驰', '驰周', '周迅'],
      );
    },
  );
  test(
    'current server expands 周驰 without enumerating Persons or waiting for pictures',
    () async {
      final calls = <Uri>[];
      final api = EmbyClient(
        client: MockClient((r) async {
          calls.add(r.url);
          expect(r.url.queryParameters['UserId'], syntheticSession().userId);
          final q =
              r.url.queryParameters['SearchTerm'] ??
              r.url.queryParameters['NameStartsWith'];
          expect(q, isNotNull);
          return response(
            jsonEncode({
              'Items': q == '周'
                  ? [
                      {'Id': 'zhou', 'Name': '周星驰', 'Type': 'Person'},
                      {'Id': 'no-image', 'Name': '周迅', 'Type': 'Person'},
                      {'Id': 'wrong', 'Name': '刘德华', 'Type': 'Person'},
                    ]
                  : [],
              'TotalRecordCount': q == '周' ? 3 : 0,
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      final seen = <ItemPage>[];
      final first = await api.searchPeople('周驰', onPartial: seen.add);
      expect(first.items.first.id, 'zhou');
      for (var i = 0; i < 30 && calls.length < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(calls.length, 6);
      expect(seen.last.items.map((i) => i.id), ['zhou', 'no-image']);
      expect(calls.any((u) => u.queryParameters['SearchTerm'] == '驰'), true);
      api.close();
    },
  );
  test(
    'long query has bounded wave and exposes remaining character branches on more even with zero matches',
    () async {
      final s = BroadSearch(persons: true), terms = <String>[];
      Future<ItemPage> fetch(String q, int at, bool prefix) async {
        terms.add(q);
        return ItemPage(q == '丁' ? [actor('d', '丁')] : [], q == '丁' ? 1 : 0);
      }

      final first = await s.search(
        '甲乙丙丁戊',
        fetch: fetch,
        allowed: () => true,
        early: false,
      );
      expect(first.items, isEmpty);
      expect(first.total, 1);
      expect(terms.length, 6);
      final next = await s.search(
        '甲乙丙丁戊',
        fetch: fetch,
        allowed: () => true,
        early: false,
        continueSearch: true,
      );
      expect(next.items.single.id, 'd');
      expect(terms.length, 12);
      expect(next.total, 1);
    },
  );
  test(
    'late stronger actor reorders first page without duplicate and later pagination never repeats IDs',
    () async {
      final s = BroadSearch(persons: true),
          gate = Completer<ItemPage>(),
          seen = <ItemPage>[];
      Future<ItemPage> fetch(String q, int at, bool prefix) async {
        if (q == '周驰' && !prefix) return gate.future;
        return ItemPage([actor('partial', '周迅'), actor('gap', '周星驰')], 2);
      }

      final first = await s.search(
        '周驰',
        fetch: fetch,
        allowed: () => true,
        onPartial: seen.add,
      );
      expect(first.items.first.id, 'gap');
      gate.complete(ItemPage([actor('exact', '周驰')], 1));
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(seen.last.items.map((i) => i.id), ['exact', 'gap', 'partial']);
      final next = await s.search(
        '周驰',
        start: 3,
        fetch: fetch,
        allowed: () => true,
      );
      expect(next.items, isEmpty);
    },
  );
  test(
    'two requests maximum; canceled query issues no queued character calls',
    () async {
      final s = BroadSearch(persons: true), gates = <Completer<ItemPage>>[];
      var allowed = true;
      final job = s.search(
        '甲乙丙丁',
        allowed: () => allowed,
        early: false,
        fetch: (q, at, prefix) {
          final g = Completer<ItemPage>();
          gates.add(g);
          return g.future;
        },
      );
      expect(gates.length, 2);
      allowed = false;
      for (final g in gates) {
        g.complete(ItemPage([actor('old', '甲')], 1));
      }
      expect((await job).items, isEmpty);
      expect(gates.length, 2);
    },
  );
  test(
    'server cursor advances by raw rows, duplicate-only pages still allow more',
    () async {
      final s = BroadSearch(), calls = <int>[];
      Future<ItemPage> fetch(String q, int at, bool p) async {
        calls.add(at);
        return ItemPage(
          at < 96
              ? List.generate(48, (i) => actor('dup', '周'))
              : [actor('last', '周末')],
          97,
        );
      }

      final first = await s.search(
        '周',
        fetch: fetch,
        allowed: () => true,
        early: false,
      );
      expect(first.items.single.id, 'dup');
      final empty = await s.search(
        '周',
        start: 1,
        fetch: fetch,
        allowed: () => true,
        early: false,
      );
      expect(empty.items, isEmpty);
      expect(empty.total, 2);
      final finalPage = await s.search(
        '周',
        start: 1,
        fetch: fetch,
        allowed: () => true,
        early: false,
      );
      expect(finalPage.items.single.id, 'last');
      expect(calls, [0, 48, 96]);
    },
  );
  test(
    'catalogue uses same literal matching, keeps pinyin precision and filters',
    () {
      final data = prepareCatalog([
        MediaItem({
          'Id': 'm',
          'Name': '流浪地球',
          'Type': 'Movie',
          'ProductionYear': 2019,
        }),
        MediaItem({
          'Id': 's',
          'Name': '流星花园',
          'Type': 'Series',
          'ProductionYear': 2001,
        }),
        MediaItem({'Id': 'd', 'Name': '斗破苍穹', 'Type': 'Series'}),
      ]);
      expect(selectCatalog((data, '流地', null)).items.map((i) => i.id).toSet(), {
        'm',
        's',
      });
      expect(selectCatalog((data, 'doupo', null)).items.single.id, 'd');
      expect(
        selectFilteredCatalog((
          data,
          '流地',
          null,
          const CatalogFilters(kind: CatalogKind.movie),
        )).items.single.id,
        'm',
      );
    },
  );
  test(
    'federated character queries retain user identity and later source results',
    () async {
      final first = syntheticSession();
      final second = Session(
        base: first.base,
        userId: 'second',
        token: 'SECOND',
        username: 'second',
        deviceId: 'fixture',
      );
      final users = <String>{};
      final api = EmbyClient(
        client: MockClient((r) async {
          users.add(r.headers['X-Emby-Token']!);
          final q = r.url.queryParameters['SearchTerm'];
          return response(
            jsonEncode({
              'Items': q == '地'
                  ? [
                      {'Id': 'same', 'Name': '流浪地球', 'Type': 'Movie'},
                    ]
                  : [],
              'TotalRecordCount': q == '地' ? 1 : 0,
            }),
            200,
          );
        }),
      );
      final c = FederatedSearch(api, [
        SavedAccount(first),
        SavedAccount(second),
      ]);
      await c.search('流地');
      expect(c.sources.map((s) => s.items.single.id), ['same', 'same']);
      expect(users, {first.token, 'SECOND'});
      expect(api.session, isNull);
      c.dispose();
      api.close();
    },
  );
}
