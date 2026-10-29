import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/detail.dart';
import 'core_test.dart' show syntheticSession, response;

MediaItem episode(int n) => MediaItem({
  'Id': 'e$n',
  'Type': 'Episode',
  'Name': '合成第$n集',
  'SeriesId': 's',
  'SeasonId': 'season',
  'ParentIndexNumber': 1,
  'IndexNumber': n,
});

class _Browse extends BrowseRepository {
  _Browse(super.api, super.cache, super.preferences, this.count);
  final int count;
  final pending = Completer<ItemPage>();
  @override
  BrowseRecord? peek(String query) =>
      query == BrowseRepository.episodeCatalogueKey('s', 'season')
      ? BrowseRecord(
          List.generate(count, (i) => episode(i + 1)),
          count,
          DateTime.utc(2026, 10, 1),
        )
      : null;
  @override
  Future<ItemPage> episodeCatalogue(
    String id,
    String season, {
    bool force = false,
    bool Function()? allowed,
  }) => pending.future;
}

void main() {
  for (final size in [const Size(412, 915), const Size(1280, 800)]) {
    for (final cachedCount in [28, 60]) {
      for (final mode in ['auto', 'scroll', 'range', 'all']) {
        final manual = mode != 'auto';
        testWidgets('watched row stays first after catalogue growth '
            '$size cache=$cachedCount mode=$mode', (tester) async {
          VisibilityDetectorController.instance.updateInterval = Duration.zero;
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          final api = EmbyClient(
            client: MockClient((r) async {
              if (r.url.path.endsWith('/Seasons')) {
                return response(
                  '{"Items":[{"Id":"season","IndexNumber":1}]}',
                  200,
                );
              }
              return response('{"Id":"s","Type":"Series","Name":"合成剧"}', 200);
            }),
          )..session = syntheticSession();
          final browse = _Browse(
            api,
            BrowseCache(prefs),
            BrowsePreferences(prefs),
            cachedCount,
          );
          await tester.pumpWidget(
            MaterialApp(
              home: DetailPage(
                item: MediaItem({'Id': 's', 'Type': 'Series', 'Name': '合成剧'}),
                api: api,
                browse: browse,
                resumeEpisode: episode(26),
                watchedEpisode: (_) async => episode(26),
                play: (_, _, _) async {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          if (size.width < size.height) {
            await tester.tap(find.text('剧集'));
            await tester.pumpAndSettle();
          }
          final list = find.byKey(const PageStorageKey('detail-episodes'));
          final scroll = tester.widget<ListView>(list).controller!;
          if (mode == 'scroll') {
            await tester.drag(list, const Offset(0, 180));
            await tester.pumpAndSettle();
          } else if (mode == 'range') {
            await tester.tap(find.byKey(const ValueKey('episode-range-0')));
            await tester.pumpAndSettle();
          } else if (mode == 'all') {
            await tester.tap(find.byKey(const Key('episode-ranges-all')));
            await tester.pumpAndSettle();
            await tester.tap(
              find.text('1–${cachedCount < 50 ? cachedCount : 50}').last,
            );
            await tester.pumpAndSettle();
          }
          final before = scroll.offset;
          browse.pending.complete(
            ItemPage(List.generate(80, (i) => episode(i + 1)), 80),
          );
          await tester.pumpAndSettle();
          if (manual) {
            expect(
              scroll.offset,
              closeTo(before, .5),
              reason: 'late refresh must respect user scrolling',
            );
          } else {
            final target = find.byKey(const ValueKey('detail-episode-e26'));
            expect(target.hitTestable(), findsOneWidget);
            expect(
              tester.getTopLeft(target).dy,
              closeTo(tester.getTopLeft(list).dy, .5),
              reason:
                  'following episodes now fill the viewport; watched row must be first',
            );
          }
          await tester.pumpWidget(const SizedBox());
          browse.dispose();
          api.close();
        });
      }
    }
  }
}
