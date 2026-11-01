import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/actor_search_results.dart';
import 'package:yingyu/ui/browse_page.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/release_refresh.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show response;
import 'search183_test.dart' show source;
import 'player_episode_menu_test.dart' show fonts;
import 'phone_layout_test.dart' show setDisplay;
import 'offline_capture.dart';
import 'offline_settle.dart';

void main() {
  setUpAll(fonts);
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    for (final homeSearch in [true, false]) {
      testWidgets(
        'default ${homeSearch ? 'home' : 'library'} search aggregates without another entry $size',
        (tester) async {
          setDisplay(tester, size);
          SharedPreferences.setMockInitialValues({});
          syntheticImagePaths();
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          final pause = Object();
          PosterDemand.pause(pause, true);
          final store = AppStore(await SharedPreferences.getInstance());
          await store.log.setEnabled(false);
          await store.accounts.load(store.deviceId);
          await store.accounts.saveAndSelect(source(1));
          await store.accounts.saveAndSelect(source(2));
          final calls = <String>[];
          final api = EmbyClient(
            client: MockClient((r) async {
              final current = r.url.host == 'server1.invalid';
              final term = r.url.queryParameters['SearchTerm'] ?? '';
              if (r.url.path.endsWith('/Views')) {
                return response('{"Items":[]}', 200);
              }
              if (r.url.path.endsWith('/Persons')) {
                return response(
                  jsonEncode({
                    'Items': [
                      {'Id': 'actor', 'Name': '片中演员', 'Type': 'Person'},
                    ],
                    'TotalRecordCount': 1,
                  }),
                  200,
                );
              }
              calls.add(
                '${current ? 'A' : 'B'}:$term:${r.headers['X-Emby-Token']}',
              );
              return response(
                jsonEncode({
                  'Items': [
                    {
                      'Id': 'same',
                      'Name':
                          '${term.isEmpty ? '片' : term}${current ? 'A' : 'B'}',
                      'Type': 'Movie',
                    },
                  ],
                  'TotalRecordCount': 1,
                }),
                200,
              );
            }),
          )..session = source(1);
          String? selected;
          final boundary = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(homeSearch ? Brightness.dark : Brightness.light),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(
                  body: LibraryPage(
                    api: api,
                    searchMode: homeSearch,
                    searchStore: store,
                    onItem: (_) async {},
                    onSearchItem:
                        (SavedAccount account, MediaItem entry) async {
                          selected = '${account.session.userId}:${entry.id}';
                        },
                  ),
                ),
              ),
            ),
          );
          await settleOffline(tester);
          expect(find.byKey(const Key('open-federated-search')), findsNothing);
          expect(find.byKey(const Key('federated-search')), findsNothing);
          expect(calls.where((c) => c.startsWith('B:')), isEmpty);
          await tester.enterText(find.byKey(const Key('library-search')), '片');
          await tester.pump(const Duration(milliseconds: 600));
          await settleOffline(tester);
          expect(calls.where((c) => c.startsWith('B:片:')), ['B:片:TOKEN_2']);
          expect(find.byType(ActorSearchResults), findsOneWidget);
          expect(find.text('片中演员'), findsOneWidget);
          expect(calls.where((c) => c.startsWith('A:片:')).length, 1);
          await tester.scrollUntilVisible(
            find.text('片B'),
            180,
            scrollable: find
                .descendant(
                  of: find.byType(ReleaseRefreshScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.drag(
            find
                .descendant(
                  of: find.byType(ReleaseRefreshScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
            const Offset(0, -350),
          );
          await tester.pumpAndSettle();
          expect(find.text('片B'), findsOneWidget);
          expect(tester.getCenter(find.text('片B')).dy, lessThan(size.height));
          await captureOffline(
            tester,
            boundary,
            'search198-${size.width.toInt()}-${homeSearch ? 'home' : 'library'}',
          );
          await tester.tap(find.text('片B'));
          await tester.pump();
          expect(selected, 'user2:same');
          expect(api.session!.userId, 'user1');
          await tester.enterText(find.byKey(const Key('library-search')), '新');
          await tester.pump(const Duration(milliseconds: 600));
          await settleOffline(tester);
          await tester.scrollUntilVisible(
            find.text('新B'),
            180,
            scrollable: find
                .descendant(
                  of: find.byType(ReleaseRefreshScrollView),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text('片B'), findsNothing);
          expect(calls.where((c) => c.startsWith('B:新:')), ['B:新:TOKEN_2']);
          await tester.enterText(find.byKey(const Key('library-search')), '');
          await tester.pump(const Duration(milliseconds: 600));
          await settleOffline(tester);
          expect(find.text('新B'), findsNothing);
          expect(calls.where((c) => c.startsWith('B::')), isEmpty);
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
}
