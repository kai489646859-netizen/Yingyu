import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/ui/detail.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/poster.dart';
import 'core_test.dart' show syntheticSession, response;
import 'phone_layout_test.dart' show setDisplay;
import 'offline_settle.dart' show syntheticImagePaths;

class _Cache extends Fake implements CacheManager, ImageCacheManager {
  _Cache(this.kind, this.starts);
  final String kind;
  final List<String> starts;
  final streams = <String, StreamController<FileResponse>>{};
  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async => null;
  @override
  Stream<FileResponse> getImageFile(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
    int? maxHeight,
    int? maxWidth,
  }) {
    return streams.putIfAbsent(url, () {
      starts.add(kind);
      return StreamController<FileResponse>.broadcast();
    }).stream;
  }
}

void main() {
  for (final failed in [true, false]) {
    testWidgets(
      'detail starts background first; releases pictures on ${failed ? 'failure' : 'bounded stall'}',
      (tester) async {
        syntheticImagePaths();
        setDisplay(tester, const Size(1280, 800));
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        final starts = <String>[];
        final oldPoster = posterCache,
            oldArtwork = artworkCache,
            oldActor = actorCache;
        final poster = _Cache('poster', starts),
            art = _Cache('artwork', starts),
            actor = _Cache('actor', starts);
        posterCache = poster;
        artworkCache = art;
        actorCache = actor;
        final data = {
          'Id': 'movie-$failed',
          'Type': 'Movie',
          'Name': 'Fixture',
          'ImageTags': {'Primary': 'poster'},
          'BackdropImageTags': ['background'],
          'People': [
            {
              'Id': 'person-$failed',
              'Name': 'Actor',
              'PrimaryImageTag': 'actor',
            },
          ],
        };
        final api = EmbyClient(
          client: MockClient((_) async => response(jsonEncode(data), 200)),
        )..session = syntheticSession();
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          posterCache = oldPoster;
          artworkCache = oldArtwork;
          actorCache = oldActor;
          for (final cache in [poster, art, actor]) {
            for (final c in cache.streams.values) {
              await c.close();
            }
          }
          api.close();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: DetailPage(
              item: MediaItem(data),
              api: api,
              play: (_, _, _) async {},
            ),
          ),
        );
        for (var n = 0; n < 8; n++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(starts, ['artwork']);
        if (failed) {
          art.streams.values.single.addError(
            StateError('synthetic image failure'),
          );
        } else {
          await tester.pump(const Duration(seconds: 8));
        }
        for (var n = 0; n < 8; n++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(starts, containsAll(['artwork', 'poster', 'actor']));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
