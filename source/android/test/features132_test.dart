import 'dart:convert';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/episode_bands.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/episode_band_picker.dart';
import 'package:yingyu/ui/people.dart';
import 'offline_settle.dart' show syntheticImagePaths;
import 'core_test.dart' show syntheticSession, response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() { syntheticImagePaths(); VisibilityDetectorController.instance.updateInterval = Duration.zero; });
  test(
    'actor storage quota persists independently and next preparation defaults on',
    () async {
      SharedPreferences.setMockInitialValues({});
      final p = await SharedPreferences.getInstance();
      final settings = InterfacePreferences(p);
      expect(settings.prepareNext, true);
      final posterGB = settings.cacheGB;
      for (final n in [1, 3, 5]) {
        await settings.setActorCacheGB(n);
        expect(InterfacePreferences(p).actorCacheGB, n);
        expect(settings.cacheGB, posterGB);
      }
      await settings.setActorCacheGB(9);
      expect(settings.actorCacheGB, 5);
      await settings.setPrepareNext(false);
      expect(InterfacePreferences(p).prepareNext, false);
      settings.dispose();
    },
  );
  test(
    'actor and poster downloads use the same request scheduler and different byte quotas',
    () {
      expect(
        identical(
          actorCache.config.fileService,
          posterCache.config.fileService,
        ),
        true,
      );
      expect(
        identical(
          actorCache.config.fileService,
          artworkCache.config.fileService,
        ),
        true,
      );
      expect(identical(actorCacheBudget, imageCacheBudget), false);
      expect(actorCache.config.cacheKey, isNot(posterCache.config.cacheKey));
    },
  );
  test(
    'actor queries use current account and person identity; no playback or progress calls',
    () async {
      final calls = <String>[];
      final api = EmbyClient(
        client: MockClient((request) async {
          calls.add(request.url.path);
          expect(request.method, 'GET');
          final q = request.url.queryParameters;
          if (request.url.path.endsWith('/Persons')) {
            expect(q['SearchTerm'], '演员姓名');
            expect(q['StartIndex'], '48');
            expect(q['UserId'], syntheticSession().userId);
          } else {
            expect(q['PersonIds'], 'person-id');
            expect(q['SearchTerm'], null);
            expect(q['IncludeItemTypes'], 'Movie,Series');
          }
          return response('{"Items":[],"TotalRecordCount":0}', 200);
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      await api.people('演员姓名', start: 48);
      await api.personItems(id: 'person-id', name: '演员姓名');
      expect(calls.length, 2);
    },
  );
  test(
    'subtitle search is read-only and server download requires explicit separate call',
    () async {
      final calls = <String>[];
      final api = EmbyClient(
        client: MockClient((request) async {
          calls.add(request.method);
          expect(request.url.queryParameters['MediaSourceId'], 'source');
          if (request.method == 'GET') {
            return response(
              jsonEncode([
                {'Id': 'sub', 'Name': '合成字幕'},
              ]),
              200,
            );
          }
          expect(
            request.url.path.endsWith('/RemoteSearch/Subtitles/sub'),
            true,
          );
          return response('{"NewIndex":3}', 200);
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      expect(
        (await api.searchSubtitles('item', 'chi', 'source')).single['Id'],
        'sub',
      );
      expect(calls, ['GET']);
      expect(
        (await api.downloadSubtitle('item', 'sub', 'source'))['NewIndex'],
        3,
      );
      expect(calls, ['GET', 'POST']);
    },
  );
  test(
    'one hundred million episodes represented sparsely still use fifty-number bands',
    () {
      final b = EpisodeBands([
        for (final n in [1, 49, 51, 1816, 100000051])
          MediaItem({'Id': 'e$n', 'IndexNumber': n}),
      ]);
      expect(b.count, 4);
      expect(EpisodeBands.label(0), '1–50');
      expect(EpisodeBands.label(1999999), '99999951–100000000');
      expect(b.indices.length, 4);
      expect(b.inBand(1), [2]);
      expect(b.labelAt(3), '100000051–100000051');
      expect(b.inBand(4), isEmpty);
    },
  );
  testWidgets('two million range choices only build visible rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      const CupertinoApp(
        home: Center(
          child: EpisodeBandPicker(count: 2000000, selected: 1999999),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('99999951–100000000'), findsOneWidget);
    expect(find.byType(Text).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('actor rail opens only that actor film list without artwork probes', (tester) async {
    final requests = <String>[];
    final api = EmbyClient(client: MockClient((request) async {
      requests.add(request.url.path);
      expect(request.url.queryParameters['PersonIds'], 'actor');
      return response('{"Items":[],"TotalRecordCount":0}', 200);
    }))..session = syntheticSession();
    addTearDown(api.close);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(CupertinoApp(home: CupertinoPageScaffold(child: SafeArea(
      child: PeopleRail(api: api, people: const [{'Id':'actor','Name':'合成演员','Role':'角色名字'}],
        onItem: (_) async {})))));
    await tester.pumpAndSettle();
    expect(find.text('角色名字'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.tap(find.text('合成演员'));
    await tester.pumpAndSettle();
    expect(find.text('合成演员的影片'), findsOneWidget);
    expect(find.text('Emby 未返回该演员的影片'), findsOneWidget);
    expect(requests.length, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
