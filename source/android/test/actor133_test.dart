import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/ui/people.dart';
import 'package:yingyu/ui/poster.dart';
import 'core_test.dart' show syntheticSession;
import 'offline_settle.dart' show syntheticImagePaths;
import 'player_episode_menu_test.dart' show fonts;

class PortraitCache extends Fake implements CacheManager, ImageCacheManager {
  final requests = <String, StreamController<FileResponse>>{};
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
  }) =>
      requests.putIfAbsent(url, () => StreamController<FileResponse>()).stream;
}

void main() {
  test('empty image-tags still uses Emby PrimaryImageTag', () {
    expect(
      personImage({
        'Id': 'p',
        'ImageTags': {},
        'PrimaryImageTag': 'tag',
      }).imageTag,
      'tag',
    );
  });
  testWidgets(
    'portrait has one decoded layer; loading, loaded and replaced frames stay inside round clip',
    (tester) async {
      await fonts();
      syntheticImagePaths();
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final oldCache = actorCache, cache = PortraitCache();
      actorCache = cache;
      addTearDown(() async {
        actorCache = oldCache;
        for (final controller in cache.requests.values) {
          await controller.close();
        }
      });
      final api = EmbyClient()..session = syntheticSession();
      addTearDown(api.close);
      final capture = GlobalKey();
      Future<void> view(String tag) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: capture,
                  child: Container(
                    color: Colors.white,
                    width: 300,
                    height: 240,
                    padding: const EdgeInsets.all(10),
                    child: PeopleRail(
                      api: api,
                      people: [
                        {'Id': 'p', 'Name': 'Actor', 'PrimaryImageTag': tag},
                      ],
                      onItem: (_) async {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<ui.Color> pixel(int x, int y, String name) async {
        late ui.Color color;
        await tester.runAsync(() async {
          final image =
              await (capture.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final raw = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final i = (y * image.width + x) * 4;
          color = Color.fromARGB(
            raw.getUint8(i + 3),
            raw.getUint8(i),
            raw.getUint8(i + 1),
            raw.getUint8(i + 2),
          );
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final out = File('build/ui-previews/1.3.3-actor-$name.png');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
        return color;
      }

      final file = File('build/actor133-blue.png');
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 100, 100),
          Paint()..color = const Color(0xFF0055FF),
        );
        final image = await recorder.endRecording().toImage(100, 100);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await view('first');
      final rect = tester.getRect(find.byType(Poster));
      final boundary = tester.getRect(find.byKey(capture));
      final left = (rect.left - boundary.left).round(),
          top = (rect.top - boundary.top).round();
      expect(await pixel(left, top, 'loading'), Colors.white);
      final url = cache.requests.keys.single;
      cache.requests[url]!.add(
        FileInfo(
          const LocalFileSystem().file(file.path),
          FileSource.Online,
          DateTime(2099),
          url,
        ),
      );
      for (var n = 0; n < 12; n++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(
        await pixel(left + 44, top + 46, 'loaded'),
        const Color(0xFF0055FF),
      );
      expect(await pixel(left, top, 'loaded'), Colors.white);
      await view('second');
      expect(cache.requests.length, 2);
      expect(
        await pixel(left + 44, top + 46, 'replacement'),
        isNot(const Color(0xFF0055FF)),
      );
      expect(await pixel(left, top, 'replacement'), Colors.white);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
