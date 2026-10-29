import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/actor_search_results.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'core_test.dart' show syntheticSession, response;
import 'offline_settle.dart';

void main() {
  setUp(
    () => VisibilityDetectorController.instance.updateInterval = Duration.zero,
  );
  for (final term in ['周', '星', '周星', '周星驰', '周驰']) {
    testWidgets(
      'current filtered homepage finds 周星驰 with literal fragment $term without directory enumeration',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final pause = Object();
        PosterDemand.pause(pause, true);
        final calls = <String>[];
        final api = EmbyClient(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/Persons')) {
              final query = r.url.queryParameters['SearchTerm'];
              final prefix = r.url.queryParameters['NameStartsWith'];
              calls.add(query ?? (prefix != null ? '<prefix>' : '<index>'));
              final matches = query != null
                  ? '周星驰'.contains(query)
                  : prefix != null && '周星驰'.startsWith(prefix);
              final people = [
                if (matches) {'Id': 'zhou', 'Name': '周星驰', 'Type': 'Person'},
              ];
              return response(
                jsonEncode({
                  'Items': people,
                  'TotalRecordCount': people.length,
                }),
                200,
              );
            }
            if (r.url.path.endsWith('/Views')) {
              return response('{"Items":[],"TotalRecordCount":0}', 200);
            }
            return response('{"Items":[],"TotalRecordCount":0}', 200);
          }),
        )..session = syntheticSession();
        final store = AppStore(await SharedPreferences.getInstance());
        final browse = BrowseRepository(
          api,
          store.browseCache,
          BrowsePreferences(store.prefs),
          spacing: Duration.zero,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LibraryPage(
                api: api,
                browse: browse,
                searchMode: true,
                onItem: (_) async {},
              ),
            ),
          ),
        );
        await settleOffline(tester);
        await tester.enterText(find.byKey(const Key('library-search')), term);
        for (var n = 0; n < 12; n++) {
          await tester.pump(const Duration(milliseconds: 150));
        }
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(ActorSearchResults),
            matching: find.text('周星驰'),
          ),
          findsOneWidget,
        );
        expect(calls.where((q) => q == '<index>'), isEmpty);
        expect(calls.length, lessThanOrEqualTo(6));
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        api.close();
        browse.dispose();
        store.log.dispose();
        store.dispose();
        PosterDemand.pause(pause, false);
      },
    );
  }
}
