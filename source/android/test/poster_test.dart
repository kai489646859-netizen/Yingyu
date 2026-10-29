import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/poster.dart';

class RecordingCache extends Fake implements CacheManager, ImageCacheManager {
  final requests = <String>[];
  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) {
    requests.add(url);
    return const Stream.empty();
  }
}

void main() {
  testWidgets(
    'wall posters and detail artwork select independent disk caches',
    (tester) async {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final previousPosters = posterCache, previousArtwork = artworkCache;
      final posters = RecordingCache(), artwork = RecordingCache();
      posterCache = posters;
      artworkCache = artwork;
      addTearDown(() {
        posterCache = previousPosters;
        artworkCache = previousArtwork;
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Column(
            children: [
              SizedBox(
                height: 100,
                child: Poster(url: 'https://synthetic.invalid/same'),
              ),
              SizedBox(
                height: 100,
                child: Poster(
                  url: 'https://synthetic.invalid/same',
                  kind: PosterKind.artwork,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(posters.requests, ['https://synthetic.invalid/same']);
      expect(artwork.requests, ['https://synthetic.invalid/same']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('posters begin only inside actual viewport and active page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    final oldCache = posterCache, cache = RecordingCache();
    posterCache = cache;
    addTearDown(() => posterCache = oldCache);
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                const SizedBox(
                  height: 200,
                  child: Poster(url: 'https://synthetic.invalid/visible'),
                ),
                const SizedBox(
                  height: 200,
                  child: Poster(
                    url: 'https://synthetic.invalid/inactive',
                    active: false,
                  ),
                ),
                const SizedBox(height: 500),
                const SizedBox(
                  height: 200,
                  child: Poster(url: 'https://synthetic.invalid/offscreen'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(cache.requests, ['https://synthetic.invalid/visible']);
    scroll.jumpTo(700);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(cache.requests, contains('https://synthetic.invalid/offscreen'));
    expect(
      cache.requests,
      isNot(contains('https://synthetic.invalid/inactive')),
    );
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });
}
