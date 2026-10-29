import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// FileInfo's public constructor takes package:file's File.
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/poster_motion.dart';
import 'poster_opacity.dart';
import 'poster_cached_drag_test.dart' show CachedPosterFixture;
import 'offline_settle.dart' show syntheticImagePaths;

class DelayedPosterCache extends CachedPosterFixture {
  final gate = Completer<void>();
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => gate.isCompleted ? super.getFileFromCache(key) : null;
  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) async* {
    network.add(url);
    await gate.future;
    yield files[key ?? url]!;
  }
}

void main() {
  for (final cached in [false, true]) {
    testWidgets(
      'real Poster shows pixels directly with no fade, cached=$cached',
      (tester) async {
        syntheticImagePaths();
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        final previous = posterCache;
        final cache = DelayedPosterCache();
        posterCache = cache;
        addTearDown(() => posterCache = previous);
        final url = 'https://fixture.invalid/entrance-$cached.png';
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 12, 18),
            Paint()..color = Colors.blue,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(12, 18);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/synthetic-ui-metadata/motion-$cached.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
          cache.files[url] = FileInfo(
            const LocalFileSystem().file(file.path),
            FileSource.Cache,
            DateTime(2099),
            url,
          );
        });
        if (cached) cache.gate.complete();
        bool ready() => tester
            .widgetList<RawImage>(find.byType(RawImage))
            .any((image) => image.image != null);
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 120,
                height: 180,
                child: PosterMotionScope(
                  child: PosterEntrance(
                    key: const Key('entrance'),
                    id: 'image',
                    child: Poster(url: url),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        double opacity() =>
            posterOpacity(tester, find.byKey(const Key('entrance')));
        if (!cached) {
          await tester.pump(const Duration(seconds: 2));
          expect(ready(), isFalse);
          expect(opacity(), 1);
          cache.gate.complete();
        }
        for (var n = 0; n < 50 && !ready(); n++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
        if (cached) {
          expect(find.byType(CachedNetworkImage), findsNothing);
          expect(cache.network, isEmpty);
        } else {
          final image = tester.widget<CachedNetworkImage>(
            find.byType(CachedNetworkImage),
          );
          expect(image.fadeInDuration, Duration.zero);
          expect(image.fadeOutDuration, Duration.zero);
          expect(image.placeholderFadeInDuration, Duration.zero);
        }
        await tester.pump();
        expect(
          opacity(),
          1,
          reason: 'cached or delayed pixels must not move a stationary card',
        );
        // CacheManager may serve the provider through both the resized and
        // imageBuilder paths. Observe that motion adds no further cache reads;
        // this fake does not equate cache API calls with network downloads.
        final imageReads = cache.network.length;
        expect(imageReads, cached ? 0 : greaterThan(0));
        await tester.pump(const Duration(milliseconds: 240));
        expect(opacity(), 1);
        expect(
          cache.network.length,
          imageReads,
          reason: 'animation cannot add image requests',
        );
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }
}
