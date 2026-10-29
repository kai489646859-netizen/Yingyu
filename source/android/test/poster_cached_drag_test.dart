import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// CacheManager's public FileInfo uses package:file.
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'offline_settle.dart';

class CachedPosterFixture extends Fake
    implements CacheManager, ImageCacheManager {
  final files = <String, FileInfo>{};
  final network = <String>[];
  final local = <String>[];
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    local.add(key);
    return files[key];
  }

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
    if (files[key ?? url] case final value?) yield value;
  }
}

void main() {
  testWidgets(
    'recreated visible poster displays cached pixels during drag without new downloads',
    (tester) async {
      syntheticImagePaths();
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final old = posterCache, oldArtwork = artworkCache;
      final cache = CachedPosterFixture(),
          art = CachedPosterFixture(),
          owner = Object();
      posterCache = cache;
      artworkCache = art;
      addTearDown(() {
        posterCache = old;
        artworkCache = oldArtwork;
        PosterDemand.pause(owner, false);
      });
      const url = 'https://fixture.invalid/poster?account=a';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 12, 18),
          Paint()..color = Colors.red,
        );
        final picture = recorder.endRecording(),
            file = File('build/synthetic-ui-metadata/cached-drag.png');
        final image = await picture.toImage(12, 18);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
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
      Future<void> show(
        String address, {
        PosterKind kind = PosterKind.poster,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              width: 120,
              height: 180,
              child: Poster(key: UniqueKey(), url: address, kind: kind),
            ),
          ),
        );
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await settleOffline(tester);
        }
      }

      bool pixels() => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((w) => w.image != null);
      PosterDemand.pause(owner, true);
      await show(url);
      expect(cache.local, [url]);
      expect(pixels(), true);
      expect(cache.network, isEmpty);
      await show('$url-new-account');
      expect(pixels(), false);
      expect(cache.network, isEmpty);
      await show(url, kind: PosterKind.artwork);
      expect(art.local, ['artwork:$url']);
      expect(pixels(), false);
      expect(art.network, isEmpty);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
