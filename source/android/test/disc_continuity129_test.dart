import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_ordered_reader.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'core_test.dart' show LoopbackHttpOverrides;

void main() {
  test(
    'real HTTP body stall stays pending and resumes byte-exactly on its established response',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const total = 12 * 1024 * 1024, chunk = 65536;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final client = HttpClient();
        final release = Completer<void>(), blocked = Completer<void>();
        var opens = 0, parts = 0;
        server.listen((request) async {
          opens++;
          final start = int.parse(
            RegExp(
              r'bytes=(\d+)-',
            ).firstMatch(request.headers.value('range')!)![1]!,
          );
          final response = request.response;
          response.statusCode = 206;
          response.contentLength = total - start;
          response.headers.set(
            'content-range',
            'bytes $start-${total - 1}/$total',
          );
          response.headers.set('etag', '"generated129"');
          try {
            for (var at = start; at < total; at += chunk) {
              if (at == 8 * 1024 * 1024) {
                if (!blocked.isCompleted) blocked.complete();
                await release.future;
              }
              response.add(
                Uint8List(chunk)..fillRange(0, chunk, (at ~/ chunk) % 251),
              );
              await response.flush();
            }
            await response.close();
          } catch (_) {
            response.detachSocket().then((socket) => socket.destroy()).ignore();
          }
        });
        final url = 'http://127.0.0.1:${server.port}/generated.m2ts';
        final reader = DiscOrderedReader(
          (path, start, token) async {
            final request = await client.getUrl(Uri.parse(url));
            request.headers.set('range', 'bytes=$start-');
            final response = await request.close();
            expect(response.statusCode, 206);
            return DiscStreamSource(
              start: start,
              total: total,
              bytes: response,
              identity: DiscStreamIdentity(url, '"generated129"', total),
              canResume: true,
              close: (_) => request.abort(),
            );
          },
          maxBytes: 12 * 1024 * 1024,
          openPart: (path, start, end, id, token) async {
            parts++;
            throw StateError(
              'ordinary-speed temporary starvation must keep the live response',
            );
          },
        );
        try {
          for (var at = 0; at < 8 * 1024 * 1024; at += chunk) {
            final b = await reader.read('', at, chunk, DiscReadCancellation());
            expect(b.bytes, everyElement((at ~/ chunk) % 251));
          }
          await blocked.future.timeout(const Duration(seconds: 2));
          var delivered = false;
          final pending = reader
              .read('', 8 * 1024 * 1024, chunk, DiscReadCancellation())
              .then((b) {
                delivered = true;
                return b;
              });
          reader.setBuffering(true);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(
            delivered,
            false,
            reason:
                'unavailable data must not be reported as playback progress',
          );
          release.complete();
          final b = await pending.timeout(const Duration(seconds: 2));
          expect(b.bytes, everyElement(128 % 251));
          reader.setBuffering(false);
          for (var at = 8 * 1024 * 1024 + chunk; at < total; at += chunk) {
            final b = await reader.read('', at, chunk, DiscReadCancellation());
            expect(b.bytes, everyElement((at ~/ chunk) % 251));
          }
          expect(opens, 1);
          expect(parts, 0);
          expect(reader.peakResponses, 1);
        } finally {
          if (!release.isCompleted) release.complete();
          await reader.close();
          client.close(force: true);
          await server.close(force: true);
        }
      }, LoopbackHttpOverrides());
    },
  );
}
