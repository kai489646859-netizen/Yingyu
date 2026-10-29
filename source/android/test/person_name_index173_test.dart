import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/person_name_index.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/emby.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem person(int id, String name) =>
    MediaItem({'Id': 'p$id', 'Name': name, 'Type': 'Person'});
void main() {
  test(
    'paged name substring search covers middle characters, local pages and one shared directory',
    () async {
      final index = PersonNameIndex(), offsets = <int>[];
      final names = List.generate(
        600,
        (n) => person(
          n,
          n == 599
              ? '周星驰'
              : n % 2 == 0
              ? '周$n'
              : '其他$n',
        ),
      );
      Future<ItemPage> fetch(int start) async {
        offsets.add(start);
        return ItemPage(names.skip(start).take(256).toList(), 600);
      }

      final result = await index.search(
        '星',
        direct: () async => ItemPage([], 0),
        fetch: fetch,
        allowed: () => true,
      );
      expect(result.items.single.title, '周星驰');
      expect(offsets, [0, 256, 512]);
      final first = await index.search(
        '周',
        direct: () async => ItemPage([], 0),
        fetch: fetch,
        allowed: () => true,
      );
      final next = await index.search(
        '周',
        start: 48,
        direct: () async => throw StateError('cached local page'),
        fetch: fetch,
        allowed: () => true,
      );
      expect(first.total, 301);
      expect(first.items.length, 48);
      expect(next.items.length, 48);
      expect(
        first.items
            .map((p) => p.id)
            .toSet()
            .intersection(next.items.map((p) => p.id).toSet()),
        isEmpty,
      );
      expect(offsets, [0, 256, 512]);
    },
  );
  test(
    'exact server result is visible before directory completes; pause stops additional pages and resumes cursor',
    () async {
      final index = PersonNameIndex(),
          gate = Completer<ItemPage>(),
          partials = <ItemPage>[];
      var active = true, calls = 0;
      final job = index.search(
        '周',
        direct: () async => ItemPage([person(0, '周星驰')], 1),
        fetch: (offset) async {
          calls++;
          if (offset == 0) return gate.future;
          return ItemPage([person(1, '周迅')], 2);
        },
        allowed: () => active,
        onPartial: partials.add,
      );
      await Future<void>.delayed(Duration.zero);
      expect(partials.first.items.single.title, '周星驰');
      active = false;
      gate.complete(ItemPage([person(0, '周星驰')], 2));
      await job;
      expect(calls, 1);
      active = true;
      final done = await index.search(
        '周',
        direct: () async => ItemPage([], 0),
        fetch: (offset) async {
          expect(offset, 1);
          calls++;
          return ItemPage([person(1, '周迅')], 2);
        },
        allowed: () => active,
      );
      expect(done.total, 2);
      expect(calls, 2);
    },
  );
  test(
    'repeated server page fails visibly rather than scanning forever',
    () async {
      final index = PersonNameIndex();
      var calls = 0;
      await expectLater(
        index.search(
          '周',
          direct: () async => ItemPage([], 0),
          fetch: (_) async {
            calls++;
            return ItemPage([person(0, '周星驰')], 3);
          },
          allowed: () => true,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 2);
    },
  );
  test(
    'actual client account switch cannot commit an old in-flight person directory',
    () async {
      final oldGate = Completer<void>();
      var oldStarted = false;
      final api = EmbyClient(
        client: MockClient((r) async {
          final old = r.url.queryParameters['UserId'] == 'synthetic-user';
          if (!r.url.queryParameters.containsKey('SearchTerm') && old) {
            oldStarted = true;
            await oldGate.future;
          }
          final items = r.url.queryParameters.containsKey('SearchTerm')
              ? <Map<String, dynamic>>[]
              : [
                  {
                    'Id': old ? 'old' : 'new',
                    'Name': old ? '周旧' : '周新',
                    'Type': 'Person',
                  },
                ];
          return response(
            jsonEncode({'Items': items, 'TotalRecordCount': items.length}),
            200,
          );
        }),
      )..session = syntheticSession();
      final old = api.searchPeople('周');
      while (!oldStarted) {
        await Future<void>.delayed(Duration.zero);
      }
      final account = api.session!;
      api.session = Session(
        base: account.base,
        userId: 'other-user',
        token: 'SYNTHETIC_OTHER',
        username: 'other',
        deviceId: account.deviceId,
      );
      final fresh = await api.searchPeople('周');
      oldGate.complete();
      expect((await old).items, isEmpty);
      expect(fresh.items.single.title, '周新');
      expect((await api.searchPeople('周')).items.single.title, '周新');
      api.close();
    },
  );
}
