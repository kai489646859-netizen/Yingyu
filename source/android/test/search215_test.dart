import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/alphabet.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/broad_search.dart';
import 'package:yingyu/core/models.dart';

void main() {
  final titles = [
    '永远的菲',
    '永远的菲 第二季',
    '不是你的恋爱',
    '比宇宙更遥远的地方',
    '白沙的水族馆',
    '爱吃拉面的小泉同学',
  ];
  final items = [
    for (var i = 0; i < titles.length; i++)
      MediaItem({'Id': '$i', 'Name': titles[i], 'Type': 'Series'}),
  ];
  test(
    'cached title search excludes unrelated shared characters from screenshot',
    () {
      final prepared = prepareCatalog(items);
      expect(
        selectCatalog((
          prepared,
          '永远的菲',
          null,
        )).items.map((i) => i.title).toSet(),
        titles.take(2).toSet(),
      );
      expect(items.where((i) => matchesTitle(i, '永远的菲')).map((i) => i.id), [
        '0',
        '1',
      ]);
      expect(selectCatalog((prepared, '找不到的影片', null)).items, isEmpty);
      expect(items.where((i) => matchesTitle(i, 'yydf')).map((i) => i.id), [
        '0',
        '1',
      ]);
    },
  );
  test(
    'remote movie search never broadens a phrase to individual characters',
    () async {
      final terms = <String>[];
      final result = await BroadSearch().search(
        '永远的菲',
        allowed: () => true,
        early: false,
        fetch: (q, offset, prefix) async {
          terms.add(q);
          final matches = items.where((i) => i.title.contains(q)).toList();
          return ItemPage(matches, matches.length);
        },
      );
      expect(terms, ['永远的菲']);
      expect(result.items.map((i) => i.id), ['0', '1']);
    },
  );
}
