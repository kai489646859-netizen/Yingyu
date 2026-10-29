import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/byte_cache.dart';
import 'package:yingyu/playback/cache_policy.dart';
import 'package:yingyu/playback/cached_reader.dart';
import 'package:yingyu/playback/cached_transport.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_stream.dart';
import 'core_test.dart' show LoopbackHttpOverrides;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late PlaybackByteCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'yingyu-synthetic-video-',
    );
    cache = PlaybackByteCache(directory: () async => directory);
    await cache.configure(2 * 1024 * 1024);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test(
    'real video bytes survive closing and new cache manager, account/source scopes stay separate',
    () async {
      final bytes = Uint8List.fromList(List.generate(192, (i) => i));
      await cache.write('account-A/source-A/tag-A', 0, bytes);
      final second = PlaybackByteCache(directory: () async => directory);
      await second.configure(2048);
      expect(await second.read('account-A/source-A/tag-A', 0, 192), bytes);
      expect(await second.read('account-B/source-A/tag-A', 0, 192), isNull);
      expect(await second.read('account-A/source-B/tag-A', 0, 192), isNull);
      expect(await second.read('account-A/source-A/tag-B', 0, 192), isNull);
    },
  );
  test(
    'quota counts actual file headers and LRU removes old unprotected ranges',
    () async {
      await cache.configure(264);
      await cache.write('a', 0, List.filled(100, 1));
      await cache.write('b', 0, List.filled(100, 2));
      await cache.read('a', 0, 100);
      await cache.write('c', 0, List.filled(100, 3));
      expect(cache.usedBytes, 264);
      expect(await cache.read('b', 0, 100), isNull);
      expect(await cache.read('a', 0, 100), List.filled(100, 1));
      var onDisk = 0;
      await for (final e in directory.list()) {
        onDisk += (await e.stat()).size;
      }
      expect(onDisk, lessThanOrEqualTo(264));
    },
  );
  test(
    'protected forward ranges are not evicted and a failed write does not exceed cap',
    () async {
      await cache.configure(132);
      await cache.write('a', 0, List.filled(100, 1));
      cache.protect('a', [0]);
      expect(await cache.write('b', 0, List.filled(100, 2)), false);
      expect(cache.usedBytes, 132);
      cache.release();
      expect(await cache.write('b', 0, List.filled(100, 2)), true);
    },
  );
  test(
    'disabled clears only video directory; artwork/progress neighbours survive',
    () async {
      final other = await Directory.systemTemp.createTemp(
        'yingyu-synthetic-art-',
      );
      try {
        await File('${other.path}/poster').writeAsString('keep');
        await cache.write('a', 0, [1, 2, 3]);
        await cache.configure(0);
        expect(cache.usedBytes, 0);
        expect(await cache.write('a', 0, [1]), false);
        expect(await File('${other.path}/poster').readAsString(), 'keep');
      } finally {
        await other.delete(recursive: true);
      }
    },
  );
  test('unlimited retains bytes and explicit clearing removes them', () async {
    await cache.configure(-1);
    await cache.write('a', 0, List.filled(4096, 1));
    expect(cache.usedBytes, 4128);
    await cache.clear();
    expect(cache.usedBytes, 0);
  });
  test(
    'corrupt same-length cached bytes are refused, incomplete writes not published',
    () async {
      await cache.write('a', 0, [1, 2, 3]);
      final file = (await directory.list().toList()).whereType<File>().single;
      await file.writeAsBytes(List.filled(35, 9));
      expect(await cache.read('a', 0, 3), isNull);
      await File('${directory.path}/${'a' * 64}.partial').writeAsBytes([1, 2]);
      final reopened = PlaybackByteCache(directory: () async => directory);
      await reopened.configure(128);
      expect(await directory.list().toList(), isEmpty);
    },
  );
  test(
    'read-ahead keeps 20 minute target after temporary 3x returns to 2x or 1x',
    () {
      final policy = PlaybackReadAhead();
      expect(policy.seconds, 60);
      policy.speed(2);
      expect(policy.seconds, 600);
      policy.speed(3);
      policy.speed(2);
      policy.speed(1);
      expect(policy.seconds, 1200);
      expect(
        policy.bytes(total: 100000, duration: const Duration(seconds: 1000)),
        100000,
      );
    },
  );
  test(
    'new media starts with normal target instead of inheriting old temporary hold',
    () {
      PlaybackReadAhead().speed(3);
      expect(PlaybackReadAhead().seconds, 60);
    },
  );
  test(
    'startup reads only one small range; background window never blocks the first bytes',
    () async {
      var consumed = 0, opened = 0;
      final reader = CachedMediaReader(
        cache: cache,
        scope: 'test',
        open: (_, start, cancel) async {
          opened++;
          return DiscStreamSource(
            start: start,
            total: 1024 * 1024,
            validator: '"stable"',
            bytes: () async* {
              for (var at = start; at < 1024 * 1024; at += 65536) {
                consumed += 65536;
                yield List.filled(65536, at ~/ 65536);
              }
            }(),
            close: (_) {},
          );
        },
      );
      final bytes = await reader.read(0, 32, DiscReadCancellation());
      expect(bytes.length, 32);
      expect(opened, 1);
      expect(consumed, CachedMediaReader.blockBytes);
      await reader.close();
    },
  );
  test(
    'cache is validated before reuse and changed tag downloads new bytes',
    () async {
      Future<List<int>> play(String tag, int value) async {
        final reader = CachedMediaReader(
          cache: cache,
          scope: 'same',
          open: (_, start, cancel) async => DiscStreamSource(
            start: start,
            total: 256 * 1024,
            validator: tag,
            bytes: Stream.value(List.filled(256 * 1024, value)),
            close: (_) {},
          ),
        );
        final bytes = await reader.read(0, 100, DiscReadCancellation());
        await reader.close();
        return bytes;
      }

      expect(await play('"old"', 1), List.filled(100, 1));
      expect(await play('"new"', 2), List.filled(100, 2));
      expect(await play('"old"', 9), List.filled(100, 1));
    },
  );
  test(
    'no validator never reuses potentially stale media across opens',
    () async {
      for (final value in [1, 2]) {
        final reader = CachedMediaReader(
          cache: cache,
          scope: 'same',
          open: (_, start, cancel) async => DiscStreamSource(
            start: start,
            total: 256 * 1024,
            bytes: Stream.value(List.filled(256 * 1024, value)),
            close: (_) {},
          ),
        );
        expect(
          await reader.read(0, 12, DiscReadCancellation()),
          List.filled(12, value),
        );
        await reader.close();
      }
      expect(cache.usedBytes, 0);
    },
  );
  test(
    'HTTP ranges support random seeking, byte-exact signed redirect and persistent reread',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final bytes = Uint8List.fromList(
        List.generate(1024 * 1024, (i) => i % 251),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var entries = 0, requests = 0;
      server.listen((request) async {
        if (request.uri.path == '/entry') {
          entries++;
          request.response.statusCode = 302;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${server.port}/media?sig=%2f%7e',
          );
          await request.response.close();
          return;
        }
        requests++;
        // HttpRequest.uri normalizes percent encoding on the receiving side;
        // raw wire preservation has a separate TCP-level assertion below.
        expect(request.uri.queryParameters['sig'], '/~');
        expect(request.headers.value('X-Emby-Token'), isNull);
        final start = int.parse(
          RegExp(
            r'bytes=(\d+)-',
          ).firstMatch(request.headers.value('range')!)![1]!,
        );
        request.response.statusCode = 206;
        request.response.headers.set('etag', '"test"');
        request.response.headers.set(
          'content-range',
          'bytes $start-${bytes.length - 1}/${bytes.length}',
        );
        request.response.contentLength = bytes.length - start;
        try {
          request.response.add(bytes.sublist(start));
          await request.response.close();
        } catch (_) {}
      });
      final transport = CachedPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/entry',
        headers: {},
        cache: cache,
        scope: 'scope',
      );
      final url = await transport.start();
      final client = HttpClient();
      try {
        final head = await client.headUrl(Uri.parse(url));
        final headers = await head.close();
        expect(headers.contentLength, bytes.length);
        await headers.drain<void>();
        for (final (start, end) in [(0, 100), (750000, 750077), (0, 100)]) {
          final request = await client.getUrl(Uri.parse(url));
          request.headers.set('range', 'bytes=$start-$end');
          final response = await request.close();
          expect(response.statusCode, 206);
          expect(
            await response.expand((e) => e).toList(),
            bytes.sublist(start, end + 1),
          );
        }
        expect(entries, 1);
        expect(requests, lessThanOrEqualTo(2));
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );

  test(
    'cold disk indexing cannot delay opening or start a full-window download',
    () async {
      final gate = Completer<Directory>();
      final cold = PlaybackByteCache(directory: () => gate.future);
      final preparation = cold.configure(2 * 1024 * 1024);
      var chunksRead = 0;
      final reader = CachedMediaReader(
        cache: cold,
        scope: 'cold',
        open: (_, start, cancel) async => DiscStreamSource(
          start: start,
          total: 1024 * 1024,
          validator: '"v"',
          bytes: () async* {
            for (var block = 0; block < 4; block++) {
              chunksRead++;
              yield List.filled(CachedMediaReader.blockBytes, 7);
            }
          }(),
          close: (_) {},
        ),
      );
      expect(
        await reader
            .read(0, 8, DiscReadCancellation())
            .timeout(const Duration(seconds: 1)),
        List.filled(8, 7),
      );
      expect(cold.ready, false);
      reader.configureAhead(1024 * 1024);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        chunksRead,
        1,
        reason: 'Do not speculatively download data that cannot yet be stored',
      );
      gate.complete(directory);
      await preparation;
      await reader.close();
    },
  );
  test(
    'disk write failure reports a cache warning while demanded video bytes still arrive',
    () async {
      final identity = playbackCacheHash([
        'blocked',
        '"v"',
        CachedMediaReader.blockBytes,
      ]);
      final name = playbackCacheHash([identity, 0]);
      await Directory('${directory.path}/$name.partial').create();
      final reader = CachedMediaReader(
        cache: cache,
        scope: 'blocked',
        open: (_, start, cancel) async => DiscStreamSource(
          start: start,
          total: CachedMediaReader.blockBytes,
          validator: '"v"',
          bytes: Stream.value(List.filled(CachedMediaReader.blockBytes, 4)),
          close: (_) {},
        ),
      );
      try {
        expect(
          await reader.read(0, 12, DiscReadCancellation()),
          List.filled(12, 4),
        );
        expect(cache.usedBytes, 0);
        expect(cache.warning, contains('直接播放'));
      } finally {
        await reader.close();
      }
    },
  );
  test(
    'a seek cancels a stalled old prefetch and new location wins immediately',
    () async {
      var first = true, oldClosed = false;
      final starts = <int>[];
      final reader = CachedMediaReader(
        cache: cache,
        scope: 'seek',
        open: (_, start, cancel) async {
          starts.add(start);
          if (first) {
            first = false;
            final controller = StreamController<List<int>>();
            controller.add(List.filled(CachedMediaReader.blockBytes, 1));
            return DiscStreamSource(
              start: start,
              total: 2 * 1024 * 1024,
              validator: '"v"',
              bytes: controller.stream,
              close: (_) {
                oldClosed = true;
                unawaited(controller.close());
              },
            );
          }
          return DiscStreamSource(
            start: start,
            total: 2 * 1024 * 1024,
            validator: '"v"',
            bytes: Stream.value(List.filled(2 * 1024 * 1024 - start, 9)),
            close: (_) {},
          );
        },
      );
      await reader.read(0, 10, DiscReadCancellation());
      reader.configureAhead(1024 * 1024);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      reader.suspend();
      final bytes = await reader
          .read(1536 * 1024, 20, DiscReadCancellation())
          .timeout(const Duration(seconds: 1));
      expect(bytes, List.filled(20, 9));
      expect(oldClosed, true);
      expect(starts.last, 1536 * 1024);
      await reader.close();
    },
  );
  test(
    'wire request preserves lowercase escapes of signed media URLs',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final lines = <String>[];
      final sockets = <Socket>[];
      server.listen((socket) {
        sockets.add(socket);
        var head = '';
        var replied = false;
        socket.listen((bytes) {
          if (replied) return;
          head += String.fromCharCodes(bytes);
          if (!head.contains('\r\n\r\n')) return;
          replied = true;
          lines.add(head.split('\r\n').first);
          final size = CachedMediaReader.blockBytes;
          socket.write(
            'HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-${size - 1}/$size\r\nContent-Length: $size\r\nETag: "v"\r\nConnection: close\r\n\r\n',
          );
          socket.add(List.filled(size, 8));
          unawaited(socket.flush().then((_) => socket.close()));
        }, onError: (Object _) {});
      });
      final transport = CachedPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/movie?signature=%2f%7e',
        headers: {},
        cache: cache,
        scope: 'wire',
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        request.headers.set('range', 'bytes=0-7');
        final response = await request.close();
        expect(await response.expand((e) => e).toList(), List.filled(8, 8));
        expect(lines.single, 'GET /movie?signature=%2f%7e HTTP/1.1');
      } finally {
        client.close(force: true);
        await transport.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      }
    }, LoopbackHttpOverrides()),
  );

  test(
    'range-incompatible sources bypass caching instead of breaking existing playback',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = 4;
        request.response.write('file');
        await request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}/movie';
      final transport = CachedPlaybackTransport(
        address: address,
        headers: {},
        cache: cache,
        scope: 'fallback',
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        request.followRedirects = false;
        final response = await request.close();
        expect(response.statusCode, 307);
        expect(response.headers.value('location'), address);
        await response.drain<void>();
        expect(cache.usedBytes, 0);
        expect(cache.warning, contains('直接播放'));
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
