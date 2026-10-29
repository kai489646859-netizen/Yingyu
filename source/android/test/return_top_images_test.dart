import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:visibility_detector/visibility_detector.dart';
// FileInfo exposes package:file's file type.
// ignore: depend_on_referenced_packages
import 'package:file/local.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/image_identity.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/library.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/poster_art.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'package:yingyu/ui/scroll_to_top.dart';
import 'package:yingyu/ui/style.dart';
import 'core_test.dart' show syntheticSession, response;
import 'image_limit_test.dart' show AbortFirstImage;
import 'offline_settle.dart';
import 'poster_cached_drag_test.dart' show CachedPosterFixture;

void main() {
  setUp(syntheticImagePaths);
  for (final display in LibraryDisplay.values) {
    testWidgets(
      '$display return to top retains pixels, reads local cache, cancels downloads and resumes visible only',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        VisibilityDetectorController.instance.updateInterval = Duration.zero;
        final previous = posterCache, cache = CachedPosterFixture();
        posterCache = cache;
        addTearDown(() {
          posterCache = previous;
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
        });
        final items = [
          for (var i = 0; i < 120; i++)
            MediaItem({
              'Id': '${display.name}-$i',
              'Name': '影片 ${i.toString().padLeft(3, '0')}',
              'Type': 'Movie',
              'ImageTags': {'Primary': 'cached'},
            }),
        ];
        final api = EmbyClient(
          client: MockClient(
            (r) async => response(
              r.url.path.endsWith('/Views')
                  ? '{"Items":[]}'
                  : jsonEncode({
                      'Items': items.map((i) => i.data).toList(),
                      'TotalRecordCount': items.length,
                    }),
              200,
            ),
          ),
        )..session = syntheticSession();
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            const Rect.fromLTWH(0, 0, 12, 18),
            Paint()..color = Colors.red,
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(12, 18);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('build/synthetic-ui-metadata/return-top.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
          picture.dispose();
          for (var i = 0; i < items.length; i++) {
            if (i % 5 == 0) continue; // Mix local hits with missing posters.
            final url = posterUrl(api, items[i])!;
            cache.files[SharedImageIdentity.key(url)] = FileInfo(
              const LocalFileSystem().file(file.path),
              FileSource.Cache,
              DateTime(2099),
              url,
            );
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(Brightness.light),
            home: Scaffold(
              body: LibraryPage(
                api: api,
                display: display,
                onItem: (_) async {},
              ),
            ),
          ),
        );
        await settleOffline(tester);
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        scroll.jumpTo(3600);
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await settleOffline(tester);
        }
        Map<String, ui.Image> pixels() {
          final result = <String, ui.Image>{};
          for (final element in find.byType(Poster).evaluate()) {
            final poster = element.widget as Poster;
            final rendered = tester.widgetList<RawImage>(
              find.descendant(
                of: find.byWidget(poster),
                matching: find.byType(RawImage),
              ),
            );
            for (final raw in rendered) {
              if (raw.image != null) result[poster.url!] = raw.image!;
            }
          }
          return result;
        }

        final before = pixels();
        expect(before, isNotEmpty);
        final attempts = cache.network.length;
        final localReads = cache.local.length;

        // The actual return button must cancel a running HTTP image request.
        final client = AbortFirstImage(), owner = Object();
        const inFlight = 'https://fixture.invalid/return-top-in-flight';
        PosterDemand.set(owner, inFlight);
        final service = PosterFileService(
          client: client,
          spacing: Duration.zero,
        );
        final cancelled = expectLater(
          service.get(inFlight),
          throwsA(isA<http.RequestAbortedException>()),
        );
        await tester.pump();
        expect(client.began.isCompleted, true);
        await tester.tap(find.byKey(const Key('scroll-to-top')));
        expect(PosterDemand.loadingPaused.value, true);
        await tester.pump();
        await cancelled;
        PosterDemand.set(owner, null);
        client.close();
        final retained = pixels();
        for (final entry in before.entries) {
          expect(
            retained[entry.key],
            same(entry.value),
            reason: 'Loaded pixels must not flash into placeholders',
          );
        }
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
          expect(PosterDemand.loadingPaused.value, true);
          expect(cache.network.length, attempts);
        }
        expect(scroll.offset, inExclusiveRange(0, 3600));
        expect(cache.local.length, greaterThan(localReads));
        expect(
          tester
              .widgetList<Image>(find.byType(Image))
              .any(
                (image) =>
                    image.image is ResizeImage &&
                    (image.image as ResizeImage).imageProvider is FileImage,
              ),
          true,
          reason:
              'Intermediate cached cards use their local file, not a network image',
        );
        for (
          var i = 0;
          i < 40 && scroll.position.isScrollingNotifier.value;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(scroll.position.isScrollingNotifier.value, false);
        expect(scroll.offset, 0);
        expect(PosterDemand.loadingPaused.value, true);
        // Flutter may defer image decoding while scroll velocity is high.
        // Once stationary, verify pixels while network work remains paused.
        for (var i = 0; i < 12 && pixels().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump();
        }
        expect(pixels(), isNotEmpty);
        VisibilityDetectorController.instance.notifyNow();
        await tester.pump(const Duration(milliseconds: 100));
        expect(PosterDemand.loadingPaused.value, true);
        expect(cache.network.length, attempts);
        await tester.pump(const Duration(milliseconds: 25));
        await tester.pump();
        expect(PosterDemand.loadingPaused.value, false);
        for (final url in cache.network.skip(attempts)) {
          expect(
            PosterDemand.visible(url),
            true,
            reason: 'Intermediate rows must not resume downloads',
          );
        }
        await tester.pumpWidget(const SizedBox());
        api.close();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'leaving a retained tab during return cannot block images on the next tab',
    (tester) async {
      final enabled = ValueNotifier(true), scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: enabled,
              builder: (_, active, child) =>
                  TickerMode(enabled: active, child: child!),
              child: ScrollToTop(
                controller: scroll,
                child: ListView.builder(
                  controller: scroll,
                  itemExtent: 100,
                  itemCount: 100,
                  itemBuilder: (_, i) => Text('Row $i'),
                ),
              ),
            ),
          ),
        ),
      );
      scroll.jumpTo(3000);
      await tester.pump();
      await tester.tap(find.byKey(const Key('scroll-to-top')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(PosterDemand.loadingPaused.value, true);
      enabled.value = false;
      await tester.pump();
      await tester.pump();
      expect(PosterDemand.loadingPaused.value, false);
      expect(scroll.position.isScrollingNotifier.value, false);
      final stopped = scroll.offset;
      expect(stopped, inExclusiveRange(0, 3000));
      enabled.value = true;
      await tester.pumpAndSettle();
      expect(scroll.offset, stopped);
      await tester.tap(find.byKey(const Key('scroll-to-top')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 125));
      expect(scroll.offset, 0);
      expect(PosterDemand.loadingPaused.value, false);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      enabled.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'interrupted return and disposal release only their own image pause',
    (tester) async {
      final controller = ScrollController(), otherOwner = Object();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScrollToTop(
              controller: controller,
              child: ListView.builder(
                controller: controller,
                itemExtent: 100,
                itemCount: 100,
                itemBuilder: (_, i) => Text('Row $i'),
              ),
            ),
          ),
        ),
      );
      controller.jumpTo(3000);
      await tester.pump();
      await tester.tap(find.byKey(const Key('scroll-to-top')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      controller.jumpTo(1800); // A new user scroll cancels the old animation.
      await tester.pump();
      expect(PosterDemand.loadingPaused.value, true);
      await tester.pump(const Duration(milliseconds: 125));
      expect(PosterDemand.loadingPaused.value, false);
      await tester.tap(find.byKey(const Key('scroll-to-top')));
      await tester.pump();
      PosterDemand.pause(otherOwner, true);
      await tester.pumpWidget(const SizedBox());
      expect(PosterDemand.loadingPaused.value, true);
      PosterDemand.pause(otherOwner, false);
      expect(PosterDemand.loadingPaused.value, false);
      await tester.pump(const Duration(seconds: 2));
      controller.dispose();
      expect(tester.takeException(), isNull);
    },
  );
}
