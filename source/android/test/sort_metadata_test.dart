import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/library.dart';
import 'core_test.dart' show syntheticSession, response;
import 'offline_settle.dart';

void main() {
  for (final firstSort in ['PremiereDate', 'CommunityRating']) {
    testWidgets(
      'fresh V1 cache requests actual $firstSort fields once; both directions and search reorder real IDs',
      (tester) async {
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        const details = [
          {
            'Id': 'a',
            'Name': '电影A',
            'Type': 'Movie',
            'ProductionYear': 2001,
            'PremiereDate': '2030-01-01',
            'CommunityRating': 1.5,
          },
          {
            'Id': 'b',
            'Name': '电影B',
            'Type': 'Movie',
            'ProductionYear': 1995,
            'CommunityRating': 9.0,
          },
          {
            'Id': 'c',
            'Name': '影集C',
            'Type': 'Series',
            'PremiereDate': '2024-01-01',
            'CommunityRating': 5.0,
          },
          {'Id': 'd', 'Name': '影集D', 'Type': 'Series'},
        ];
        var reads = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            if (request.url.path.endsWith('/Views')) {
              return response('{"Items":[]}', 200);
            }
            expect(
              request.url.path,
              endsWith('/Items'),
              reason: 'one list request, no per-title detail or TMDB requests',
            );
            reads++;
            final fields = request.url.queryParameters['Fields']!.split(',');
            // Reproduce an Emby server which only includes optional fields when requested.
            return response(
              jsonEncode({
                'Items': [
                  for (final detail in details)
                    {
                      for (final entry in detail.entries)
                        if (['Id', 'Name', 'Type'].contains(entry.key) ||
                            fields.contains(entry.key))
                          entry.key: entry.value,
                    },
                ],
                'TotalRecordCount': 4,
              }),
              200,
            );
          }),
        )..session = syntheticSession();
        var repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        await repo.cache.put(
          repo.key(BrowseRepository.catalogueKey(null, 'alphabet')),
          ItemPage([
            for (final detail in details)
              MediaItem({
                'Id': detail['Id'],
                'Name': detail['Name'],
                'Type': detail['Type'],
                '_YingyuSortMetadataV1': true,
              }),
          ], 4),
          DateTime.now(),
        );
        Future<void> mount() async {
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
              ),
            ),
          );
          await settleOffline(tester);
        }

        Future<void> pick(String value) async {
          await tester.tap(find.byKey(const Key('library-sort')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey(value)));
          await settleOffline(tester);
        }

        List<String> ids() => tester
            .widgetList<MediaCard>(find.byType(MediaCard))
            .map((w) => w.item.id)
            .toList();
        await mount();
        expect(reads, 0);
        await pick('sort:$firstSort');
        expect(reads, 1);
        await pick('sort:PremiereDate');
        await pick('order:ascending');
        expect(ids(), ['b', 'a', 'c', 'd']);
        await pick('order:descending');
        expect(ids(), ['c', 'a', 'b', 'd']);
        await pick('sort:CommunityRating');
        expect(ids(), ['b', 'c', 'a', 'd']);
        await pick('order:ascending');
        expect(ids(), ['a', 'c', 'b', 'd']);
        await tester.enterText(find.byType(CupertinoSearchTextField), '电影');
        await settleOffline(tester);
        expect(ids(), ['a', 'c', 'b', 'd']);
        await pick('order:descending');
        expect(ids(), ['b', 'c', 'a', 'd']);
        await pick('sort:PremiereDate');
        expect(ids(), ['c', 'a', 'b', 'd']);
        await pick('order:ascending');
        expect(ids(), ['b', 'a', 'c', 'd']);
        expect(reads, 1);
        expect(
          repo
              .peekSharedCatalogue(null)!
              .items
              .every((i) => i.data['_YingyuSortMetadataV2'] == true),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox());
        repo.dispose();
        repo = BrowseRepository(
          api,
          BrowseCache(prefs),
          BrowsePreferences(prefs),
          spacing: Duration.zero,
        );
        await mount();
        expect(
          reads,
          1,
          reason:
              'unknown year/rating remains unknown after restart, no refresh loop',
        );
        await tester.pumpWidget(const SizedBox());
        repo.dispose();
        api.close();
      },
    );
  }
}
