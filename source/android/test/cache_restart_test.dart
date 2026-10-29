import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/catalog.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/library.dart';
import 'core_test.dart' show syntheticSession, response;

void main() {
  for (final sort in ['alphabet', 'SortName']) {
    for (final stale in [false, true]) {
      testWidgets(
        'fresh process restores $sort catalogue before a slow/failing Views request, stale=$stale',
        (tester) async {
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          SharedPreferences.setMockInitialValues({
            'yingyu.browse.sort.v1': sort,
          });
          final before = await SharedPreferences.getInstance();
          final now = DateTime.utc(2026, 10, 7, 12);
          final at = stale ? now.subtract(const Duration(days: 1)) : now;
          final account = syntheticSession();
          final catalogue = prepareCatalog(
            List.generate(
              60,
              (i) => MediaItem({
                'Id': 'm$i',
                'Name': 'Alpha ${i.toString().padLeft(3, '0')}',
                'Type': 'Movie',
              }),
            ),
          );
          await BrowseCache(before).put(
            jsonEncode([
              account.base.toString(),
              account.userId,
              'catalogue:v1:${jsonEncode([null, sort])}',
            ]),
            ItemPage(catalogue, 60),
            at,
          );
          final savedBytes = before.getString(BrowseCache.storageKey)!;
          // Drop all object identity and memory view state, as a new process does.
          SharedPreferences.setMockInitialValues({
            'yingyu.browse.sort.v1': sort,
            BrowseCache.storageKey: savedBytes,
          });
          final prefs = await SharedPreferences.getInstance();
          final pending = Completer<http.Response>();
          addTearDown(() {
            if (!pending.isCompleted) {
              pending.complete(response('{"Items":[]}', 200));
            }
          });
          var itemCalls = 0;
          final api = EmbyClient(
            client: MockClient((request) {
              if (request.url.path.endsWith('/Views')) return pending.future;
              itemCalls++;
              return Future.value(response('temporary failure', 503));
            }),
          )..session = account;
          final repo = BrowseRepository(
            api,
            BrowseCache(prefs),
            BrowsePreferences(prefs),
            now: () => now,
            spacing: Duration.zero,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: LibraryPage(api: api, browse: repo, onItem: (_) async {}),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.text('Alpha 000').hitTestable(), findsOneWidget);
          expect(
            itemCalls,
            0,
            reason: 'Cached display must not wait for server metadata',
          );
          pending.complete(response('{"Items":[]}', 200));
          await tester.pumpAndSettle();
          expect(find.text('Alpha 000').hitTestable(), findsOneWidget);
          expect(itemCalls, stale ? 1 : 0);
          if (stale) expect(find.textContaining('HTTP 503'), findsWidgets);
          expect(
            BrowseCache(prefs)
                .get(repo.key(BrowseRepository.catalogueKey(null, sort)))!
                .items
                .length,
            60,
          );
          await tester.pumpWidget(const SizedBox());
          repo.dispose();
          api.close();
        },
      );
    }
  }
}
