import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/image_loading.dart';
import 'package:yingyu/core/interface_preferences.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/ui/poster_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'fast default and all user choices persist independently of refresh interval',
    () async {
      SharedPreferences.setMockInitialValues({'yingyu.browse.minutes.v1': 5});
      final prefs = await SharedPreferences.getInstance();
      final p = InterfacePreferences(prefs);
      expect(p.imageLoadSpeed, ImageLoadSpeed.fast);
      for (final speed in ImageLoadSpeed.values) {
        await p.setImageLoadSpeed(speed);
        expect(InterfacePreferences(prefs).imageLoadSpeed, speed);
      }
      await prefs.setString('yingyu.images.speed.v1', 'invalid');
      expect(p.imageLoadSpeed, ImageLoadSpeed.fast);
      expect(prefs.getInt('yingyu.browse.minutes.v1'), 5);
      p.dispose();
    },
  );
  for (final speed in ImageLoadSpeed.values) {
    test(
      '${speed.name}: starts are spaced while response concurrency stays bounded',
      () async {
        final watch = Stopwatch()..start();
        final starts = <int>[];
        final firstBody = Completer<void>(), began = Completer<void>();
        var active = 0, peak = 0;
        Stream<List<int>> body(bool first) async* {
          active++;
          if (active > peak) peak = active;
          yield [1];
          if (first) await firstBody.future;
          active--;
        }

        final service = PosterFileService(
          spacing: speed.interval,
          visible: (_) => true,
          client: MockClient.streaming((_, _) async {
            starts.add(watch.elapsedMilliseconds);
            if (starts.length == 1) began.complete();
            return http.StreamedResponse(body(starts.length == 1), 200);
          }),
        );
        final pending = [
          for (var i = 0; i < 3; i++)
            service.get('https://fixture.invalid/image$i'),
        ];
        await began.future;
        await Future<void>.delayed(const Duration(milliseconds: 450));
        expect(starts.length, speed == ImageLoadSpeed.fast ? 2 : 1);
        firstBody.complete();
        final results = await Future.wait(pending);
        expect(results.map((r) => r.statusCode), [200, 200, 200]);
        expect(peak, lessThanOrEqualTo(2));
        if (speed == ImageLoadSpeed.fast) expect(peak, 2);
        for (var i = 1; i < 3; i++) {
          expect(
            starts[i] - starts[i - 1],
            greaterThanOrEqualTo(speed.interval.inMilliseconds - 15),
          );
        }
      },
    );
  }
  test(
    'queued speed change slows immediately and invisible jobs never reach HTTP',
    () async {
      final watch = Stopwatch()..start();
      final starts = <String>[];
      final service = PosterFileService(
        spacing: ImageLoadSpeed.fast.interval,
        visible: (url) => !url.endsWith('hidden'),
        client: MockClient((request) async {
          starts.add(request.url.path);
          return http.Response('x', 200);
        }),
      );
      await service.get('https://fixture.invalid/first');
      final finished = watch.elapsedMilliseconds;
      final hidden = expectLater(
        service.get('https://fixture.invalid/hidden'),
        throwsA(isA<AppFailure>()),
      );
      final next = service.get('https://fixture.invalid/detail');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      service.spacing = ImageLoadSpeed.slow.interval;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(starts, ['/first']);
      await hidden;
      await next;
      expect(starts, ['/first', '/detail']);
      expect(watch.elapsedMilliseconds - finished, greaterThanOrEqualTo(1985));
    },
  );
  for (final dateHeader in [false, true]) {
    test(
      'Retry-After $dateHeader longer than five minutes is honored',
      () async {
        final epoch = DateTime.utc(2026);
        var now = epoch, calls = 0;
        final service = PosterFileService(
          now: () => now,
          spacing: Duration.zero,
          visible: (_) => true,
          client: MockClient((_) async {
            calls++;
            return http.Response(
              '',
              503,
              headers: {
                'retry-after': dateHeader
                    ? HttpDate.format(epoch.add(const Duration(minutes: 10)))
                    : '600',
              },
            );
          }),
        );
        await service.get('https://fixture.invalid/first');
        now = epoch.add(const Duration(minutes: 6));
        await expectLater(
          service.get('https://fixture.invalid/second'),
          throwsA(isA<AppFailure>()),
        );
        expect(calls, 1);
        now = epoch.add(const Duration(minutes: 10));
        await service.get('https://fixture.invalid/third');
        expect(calls, 2);
        expect(service.retryAfterSeconds('malformed'), null);
        expect(service.retryAfterSeconds('-1'), null);
      },
    );
  }
}
