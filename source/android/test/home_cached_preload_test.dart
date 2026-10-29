import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/home_feed.dart';
import 'package:yingyu/core/image_identity.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/ui/home.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'core_test.dart' show syntheticSession;
import 'poster_cached_drag_test.dart' show CachedPosterFixture;

class LocalHomeFixture extends HomeFeed {
  LocalHomeFixture(super.api, super.store);
  @override
  Future<void> refresh({bool force = false, bool reconcile = false}) async {}
}

void main() {
  testWidgets(
    'real home rails prepare a bounded local neighborhood, never downloading hidden posters',
    (tester) async {
      tester.view.physicalSize = const Size(412, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final api = EmbyClient()..session = syntheticSession();
      final feed = LocalHomeFixture(api, store);
      List<MediaItem> items(String prefix) => List.generate(
        18,
        (i) => MediaItem({
          'Id': '$prefix-$i',
          'Name': '合成 $i',
          'Type': 'Movie',
          'ImageTags': {'Primary': 'tag'},
        }),
      );
      feed.resume = items('resume');
      feed.sections = [
        HomeSection(
          MediaItem({'Id': 'movies', 'Name': '电影'}),
          items: items('latest'),
          loading: false,
        ),
      ];
      final cache = CachedPosterFixture(), landscape = CachedPosterFixture();
      final previous = posterCache, previousLandscape = landscapeCache;
      posterCache = cache;
      landscapeCache = landscape;
      addTearDown(() {
        posterCache = previous;
        landscapeCache = previousLandscape;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeDashboard(
              feed: feed,
              active: true,
              onItem: (_) async {},
              onPlay: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final rail in [feed.resume, feed.sections.single.items]) {
        final images = identical(rail, feed.resume) ? landscape : cache;
        final urls = rail.map(api.imageUrl).toList();
        final local = urls
            .where((url) => images.local.contains(SharedImageIdentity.key(url)))
            .toList();
        expect(local.length, greaterThan(identical(rail, feed.resume) ? 2 : 3));
        if (identical(rail, feed.resume)) {
          expect(local.length, lessThanOrEqualTo(4));
        }
        expect(local.length, lessThan(rail.length));
        final hidden = local
            .where((url) => !PosterDemand.visible(url))
            .toList();
        expect(hidden, isNotEmpty);
        expect(hidden.any(images.network.contains), false);
        expect(images.network.where(urls.contains), isNotEmpty);
      }
      await tester.pumpWidget(const SizedBox());
      feed.dispose();
      api.close();
      store.dispose();
    },
  );
}
