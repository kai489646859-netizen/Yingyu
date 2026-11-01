import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/federated_search.dart';
import 'package:yingyu/core/broad_search.dart';
import 'package:yingyu/core/models.dart';
import 'core_test.dart' show response, syntheticSession;

void main() {
  test(
    'failed next page keeps existing results and the exact server cursor',
    () async {
      final search = BroadSearch();
      final offsets = <int>[];
      var broken = false;
      Future<ItemPage> fetch(String query, int offset, bool prefix) async {
        offsets.add(offset);
        if (broken) throw const AppFailure('temporarily unavailable');
        return ItemPage([
          MediaItem({'Id': '$offset', 'Name': '片'}),
        ], 2);
      }

      await search.search('片', fetch: fetch, allowed: () => true, early: false);
      broken = true;
      await expectLater(
        search.search(
          '片',
          start: 1,
          fetch: fetch,
          allowed: () => true,
          early: false,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(search.ordered.map((item) => item.id), ['0']);
      expect(search.hasMore, isTrue);
      broken = false;
      final result = await search.search(
        '片',
        start: 1,
        fetch: fetch,
        allowed: () => true,
        early: false,
      );
      expect(offsets, [0, 1, 1]);
      expect(result.items.single.id, '1');
      expect(search.hasMore, isFalse);
    },
  );
  test(
    'failing multi-branch search stays bounded until the next explicit action',
    () async {
      final search = BroadSearch(persons: true);
      var calls = 0;
      Future<ItemPage> fetch(String query, int offset, bool prefix) async {
        calls++;
        throw const AppFailure('temporarily unavailable');
      }

      for (var action = 1; action <= 3; action++) {
        await expectLater(
          search.search(
            '甲乙丙丁戊己庚',
            fetch: fetch,
            allowed: () => true,
            early: false,
            continueSearch: true,
          ),
          throwsA(isA<AppFailure>()),
        );
        expect(calls, action * 6);
        expect(search.hasMore, isTrue);
      }
    },
  );
  test(
    'aggregate search retries a failed branch after the server recovers',
    () async {
      var failed = true, calls = 0;
      final api = EmbyClient(
        client: MockClient((request) async {
          calls++;
          return failed
              ? response('{}', 503)
              : response(
                  jsonEncode({
                    'Items': [
                      {'Id': 'recovered', 'Name': '片', 'Type': 'Movie'},
                    ],
                    'TotalRecordCount': 1,
                  }),
                  200,
                );
        }),
      );
      final search = FederatedSearch(api, [SavedAccount(syntheticSession())]);
      addTearDown(() {
        search.dispose();
        api.close();
      });
      await search.search('片');
      expect(search.sources.single.error, isNotNull);
      final before = calls;
      failed = false;
      await search.retry(search.sources.single);
      expect(
        calls,
        greaterThan(before),
        reason: 'Retry must actually reissue the failed query',
      );
      expect(search.sources.single.items.map((item) => item.id), ['recovered']);
      expect(search.sources.single.error, isNull);
    },
  );
}
