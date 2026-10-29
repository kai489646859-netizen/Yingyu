import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:yingyu/core/image_loading.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/alphabet_rail.dart';
import 'package:yingyu/ui/poster.dart';
import 'package:yingyu/ui/poster_service.dart';
import 'poster_test.dart' show RecordingCache;

class AbortFirstImage extends http.BaseClient {
  final began = Completer<void>();
  final paths = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    paths.add(request.url.path);
    if (paths.length == 1) {
      began.complete();
      await (request as http.AbortableRequest).abortTrigger;
      throw http.RequestAbortedException(request.url);
    }
    return http.StreamedResponse(Stream.value([1]), 200);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'per-second budget defaults to 3 and migrates explicit slower limits',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final settings = InterfacePreferences(prefs);
      expect(settings.imageRequestLimit, 3);
      expect(settings.imageLoadSpeed, ImageLoadSpeed.fast);
      for (final cap in [1, 2, 3]) {
        await settings.setImageRequestLimit(cap);
        expect(InterfacePreferences(prefs).imageRequestLimit, cap);
      }
      await prefs.setInt('yingyu.images.limit.v2', 999);
      expect(settings.imageRequestLimit, 3);
      await prefs.setInt('yingyu.images.limit.v1', 6);
      expect(settings.imageRequestLimit, 1);
      await prefs.setInt('yingyu.images.limit.v1', 10);
      expect(settings.imageRequestLimit, 2);
      settings.dispose();
    },
  );

  for (final speed in ImageLoadSpeed.values) {
    for (final limit in [1, 2, 3]) {
      test(
        '${speed.name}: every rolling second admits at most $limit attempts',
        () async {
          var clock = DateTime.utc(2026);
          final starts = <DateTime>[];
          final service = PosterFileService(
            spacing: speed.interval,
            requestLimit: limit,
            now: () => clock,
            delay: (duration) async => clock = clock.add(duration),
            visible: (_) => true,
            client: MockClient((request) async {
              starts.add(clock);
              clock = clock.add(const Duration(milliseconds: 37));
              // A failed image still consumes the budget. Use 404 to exercise
              // the rolling limit independently of the longer 429/5xx cooldown.
              return http.Response('image', starts.length % 4 == 0 ? 404 : 200);
            }),
          );
          for (var i = 0; i < 45; i++) {
            await service.get(
              'https://fixture.invalid/${i.isEven ? 'poster' : 'artwork'}/$i',
            );
          }
          for (var i = 0; i < starts.length; i++) {
            final recent = starts
                .take(i + 1)
                .where(
                  (at) => starts[i].difference(at) < const Duration(seconds: 1),
                );
            expect(recent.length, lessThanOrEqualTo(limit));
            if (i > 0) {
              expect(
                starts[i].difference(starts[i - 1]),
                greaterThanOrEqualTo(speed.interval),
              );
            }
          }
          if (speed == ImageLoadSpeed.fast && limit == 3) {
            expect(
              starts[14].difference(starts.first),
              lessThan(const Duration(seconds: 7)),
            );
            expect(
              starts[15].difference(starts.first),
              const Duration(seconds: 6),
            );
          }
        },
      );
    }
  }

  test(
    'drag aborts in-flight image, waits, drops offscreen queue and resumes without failure backoff',
    () async {
      final client = AbortFirstImage();
      final owner = Object(), pauseOwner = Object();
      var now = DateTime.utc(2026);
      final starts = <DateTime>[];
      final service = PosterFileService(
        client: client,
        spacing: Duration.zero,
        requestLimit: 1,
        now: () => now,
        delay: (duration) async {
          now = now.add(duration);
          starts.add(now);
        },
      );
      const first = 'https://fixture.invalid/first',
          last = 'https://fixture.invalid/last';
      PosterDemand.set(owner, first);
      final cancelled = expectLater(
        service.get(first),
        throwsA(isA<http.RequestAbortedException>()),
      );
      await client.began.future;
      PosterDemand.pause(pauseOwner, true);
      await cancelled;
      final obsolete = expectLater(
        service.get(first),
        throwsA(isA<AppFailure>()),
      );
      final finalImage = service.get(last);
      PosterDemand.set(owner, last);
      await Future<void>.delayed(Duration.zero);
      expect(client.paths, ['/first']);
      PosterDemand.pause(pauseOwner, false);
      await obsolete;
      expect((await finalImage).statusCode, 200);
      expect(client.paths, ['/first', '/last']);
      // Cancelled request consumed its slot; it did not cause a 30 second failure.
      expect(now, DateTime.utc(2026).add(const Duration(seconds: 1)));
      PosterDemand.set(owner, null);
      client.close();
    },
  );

  testWidgets(
    'scrubbing pauses new poster work, vibrates on changed letters and releases on disposal',
    (tester) async {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      final original = posterCache, cache = RecordingCache();
      posterCache = cache;
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(() {
        posterCache = original;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      String letter = 'A';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, change) => Row(
                children: [
                  SizedBox(
                    width: 160,
                    height: 240,
                    child: Poster(url: 'https://fixture.invalid/$letter'),
                  ),
                  SizedBox(
                    width: 44,
                    height: 594,
                    child: AlphabetRail(
                      available: const {'A', 'B', 'C'},
                      onSelect: (value) => change(() => letter = value),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(cache.requests, ['https://fixture.invalid/A']);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('alphabet-letter-B'))),
      );
      await tester.pumpAndSettle();
      expect(PosterDemand.loadingPaused.value, isTrue);
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('alphabet-letter-C'))),
      );
      await tester.pumpAndSettle();
      await gesture.moveBy(const Offset(0, 1));
      await tester.pumpAndSettle();
      expect(cache.requests, ['https://fixture.invalid/A']);
      expect(
        haptics.where((h) => h == 'HapticFeedbackType.lightImpact').length,
        1,
      );
      expect(
        haptics.where((h) => h == 'HapticFeedbackType.selectionClick').length,
        1,
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
      expect(PosterDemand.loadingPaused.value, isFalse);
      expect(cache.requests, [
        'https://fixture.invalid/A',
        'https://fixture.invalid/C',
      ]);
      final next = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('alphabet-letter-B'))),
      );
      expect(PosterDemand.loadingPaused.value, isTrue);
      await tester.pumpWidget(const SizedBox());
      expect(PosterDemand.loadingPaused.value, isFalse);
      await next.cancel();
      await tester.pumpAndSettle();
      expect(tester.takeException(), null);
    },
  );
}
