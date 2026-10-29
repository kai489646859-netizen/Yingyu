import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/byte_cache.dart';
import 'package:yingyu/playback/cached_transport.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final kind in [DiscKind.iso, DiscKind.blurayFolder]) {
    test(
      '${kind.name} uses persistent bytes across reopen and rejects changed file identity',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final dir = await Directory.systemTemp.createTemp('yingyu-disc-cache-');
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        const total = 2 * 1024 * 1024;
        var tag = 'one', value = 1;
        server.listen((request) async {
          final span = discByteRange(request.headers.value('range'), total)!;
          request.response.statusCode = 206;
          request.response.headers.set('etag', '"$tag"');
          request.response.headers.set(
            'Content-Range',
            'bytes ${span.start}-${span.end}/$total',
          );
          request.response.contentLength = span.end - span.start + 1;
          try {
            request.response.add(
              Uint8List(span.end - span.start + 1)
                ..fillRange(0, span.end - span.start + 1, value),
            );
            await request.response.close();
          } catch (_) {}
        });
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async => call.method == 'open' ? titleData : null,
        );
        final url =
            'http://127.0.0.1:${server.port}/${kind == DiscKind.iso ? 'film.iso' : 'disc/BDMV/index.bdmv'}';
        final client = HttpClient();
        Future<void> play(int expected) async {
          final cache = PlaybackByteCache(directory: () async => dir);
          await cache.configure(8 * 1024 * 1024);
          final transport = DiscTransport(
            route(url, kind: kind),
            kind: kind,
            persistentCache: cache,
            cacheScope: 'account-A/source-A',
          );
          try {
            await transport.start();
            final path = kind == DiscKind.iso ? '' : 'BDMV/STREAM/00001.m2ts';
            final request = await client.getUrl(
              Uri.parse(
                '${transport.base}/input?path=${Uri.encodeComponent(path)}',
              ),
            );
            request.headers.set('Range', 'bytes=0-127');
            final response = await request.close();
            expect(response.statusCode, 206);
            expect(
              await response.expand((v) => v).toList(),
              List.filled(128, expected),
            );
            expect(cache.usedBytes, greaterThan(128));
            expect(transport.failure, isNull);
          } finally {
            await transport.close();
          }
        }

        try {
          await play(1);
          value = 2;
          await play(
            1,
          ); // Same validated identity serves retained original bytes.
          tag = 'two';
          await play(2);
        } finally {
          client.close(force: true);
          await server.close(force: true);
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            null,
          );
          await dir.delete(recursive: true);
        }
      }, LoopbackHttpOverrides()),
    );
  }
  test(
    'new seek range cancels a stalled old demanded body without latching playback failure',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final dir = await Directory.systemTemp.createTemp('yingyu-seek-cache-');
      final cache = PlaybackByteCache(directory: () async => dir);
      await cache.configure(2 * 1024 * 1024);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const total = 2 * 1024 * 1024;
      final stalled = Completer<void>(), release = Completer<void>();
      server.listen((request) async {
        final span = discByteRange(request.headers.value('range'), total)!;
        request.response.statusCode = 206;
        request.response.headers.set('etag', '"same"');
        request.response.headers.set(
          'Content-Range',
          'bytes ${span.start}-${span.end}/$total',
        );
        request.response.contentLength = span.end - span.start + 1;
        try {
          if (span.start == 0) {
            request.response.add([1]);
            await request.response.flush();
            stalled.complete();
            await release.future;
          } else {
            request.response.add(
              Uint8List(total - span.start)
                ..fillRange(0, total - span.start, 7),
            );
          }
          await request.response.close();
        } catch (_) {}
      });
      final transport = CachedPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/movie',
        headers: {},
        cache: cache,
        scope: 'seek',
      );
      final client = HttpClient();
      Future<List<int>> get(String url, int start) async {
        final request = await client.getUrl(Uri.parse(url));
        request.headers.set('Range', 'bytes=$start-${start + 15}');
        return (await request.close()).expand((v) => v).toList();
      }

      try {
        final url = await transport.start();
        final previous = get(url, 0).catchError((Object _) => <int>[]);
        await stalled.future.timeout(const Duration(seconds: 3));
        transport.seek();
        expect(
          await get(url, 1024 * 1024).timeout(const Duration(seconds: 3)),
          List.filled(16, 7),
        );
        expect(transport.failure, isNull);
        release.complete();
        await previous;
      } finally {
        if (!release.isCompleted) release.complete();
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
        await dir.delete(recursive: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
