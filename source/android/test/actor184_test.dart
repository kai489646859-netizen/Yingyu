import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/person_query_search.dart';
import 'package:yingyu/core/models.dart';

MediaItem person(String id, String name) =>
    MediaItem({'Id': id, 'Name': name, 'Type': 'Person'});
void main() {
  test(
    'first server match appears while the other query is stalled; late matches append',
    () async {
      final search = PersonQuerySearch(),
          gate = Completer<ItemPage>(),
          seen = <ItemPage>[];
      final job = search.search(
        '周',
        allowed: () => true,
        onPartial: seen.add,
        fetch: (_, _, prefix) async =>
            prefix ? ItemPage([person('a', '周一')], 1) : gate.future,
      );
      final first = await job.timeout(const Duration(milliseconds: 200));
      expect(first.items.single.id, 'a');
      expect(seen.last.items.single.id, 'a');
      gate.complete(ItemPage([person('b', '周二')], 1));
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.items.map((p) => p.id), ['a', 'b']);
      expect(seen.last.total, 2);
    },
  );
  test(
    'new query never imports names from prior responses; removed actor stays removed',
    () async {
      final search = PersonQuerySearch();
      await search.search(
        '周',
        allowed: () => true,
        fetch: (_, _, _) async => ItemPage([person('old', '周星驰')], 1),
      );
      await Future<void>.delayed(Duration.zero);
      final fresh = await search.search(
        '周',
        allowed: () => true,
        fetch: (_, _, _) async => ItemPage([], 0),
      );
      expect(fresh.items, isEmpty);
      expect(fresh.total, 0);
    },
  );
  test(
    'query pages use independent server cursors and preserve duplicate IDs only once',
    () async {
      final search = PersonQuerySearch();
      final calls = <String>[];
      Future<ItemPage> fetch(String term, int offset, bool prefix) async {
        calls.add('$prefix:$offset');
        return offset == 0
            ? ItemPage([for (var i = 0; i < 48; i++) person('p$i', '周$i')], 49)
            : ItemPage([person('last', '周末')], 49);
      }

      final first = await search.search('周', allowed: () => true, fetch: fetch);
      expect(first.items.length, 48);
      await Future<void>.delayed(Duration.zero);
      final next = await search.search(
        '周',
        start: 48,
        allowed: () => true,
        fetch: fetch,
      );
      expect(next.items.single.id, 'last');
      await Future<void>.delayed(Duration.zero);
      expect(calls.toSet(), {'false:0', 'true:0', 'false:48', 'true:48'});
    },
  );
  test(
    'late old query response and account reset cannot repopulate new query',
    () async {
      final search = PersonQuerySearch(), gate = Completer<ItemPage>();
      final old = search.search(
        '旧',
        allowed: () => true,
        fetch: (_, _, _) => gate.future,
      );
      search.reset();
      final fresh = await search.search(
        '新',
        allowed: () => true,
        fetch: (_, _, _) async => ItemPage([person('new', '新演员')], 1),
      );
      gate.complete(ItemPage([person('old', '旧演员')], 1));
      expect((await old).items, isEmpty);
      expect(fresh.items.single.id, 'new');
    },
  );
  test('missing image metadata does not hide searchable actors', () async {
    final search = PersonQuerySearch();
    final result = await search.search(
      '周',
      allowed: () => true,
      fetch: (_, _, _) async => ItemPage([person('no-photo', '周无头像')], 1),
    );
    expect(result.items.single.id, 'no-photo');
  });
}
