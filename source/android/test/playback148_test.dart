import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'package:yingyu/playback/startup_transport.dart';
import 'origin_transport_test.dart' show route;
import 'core_test.dart' show LoopbackHttpOverrides;

typedef StartupWrapper = Future<String> Function(String address);

class _HandshakeClient implements HttpClient {
  _HandshakeClient(this.inner);
  final HttpClient inner;
  @override
  set autoUncompress(bool value) => inner.autoUncompress = value;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) {
    if (uri.scheme == 'https') throw HandshakeException('synthetic handshake');
    return inner.openUrl(method, uri);
  }

  @override
  Future<HttpClientRequest> getUrl(Uri uri) => openUrl('GET', uri);
  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HandshakeOverrides extends LoopbackHttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _HandshakeClient(super.createHttpClient(context));
}

/// Replay the actual exported 0 -> tail64 -> 429363 request/cancellation shape.
/// Only synthetic bytes and controlled local HTTP; no user media/server.
Future<
  ({int entryCalls, int resumedBodies, int upstreamRequests, bool available})
>
startupProbe(
  StartupWrapper wrap, {
  bool strongTag = true,
  bool changedTail = false,
  bool redirectTail = false,
  int resume = 429363,
}) async {
  const total = 32 * 1024 * 1024;
  final bodyGate = Completer<void>();
  final coldGate = Completer<void>();
  final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var entryCalls = 0, resumedBodies = 0, upstreamRequests = 0;
  final clients = <HttpClient>[];
  final origin = EmbyOriginTransport(route('http://127.0.0.1:${entry.port}'));
  upstream.listen((request) async {
    upstreamRequests++;
    try {
      expect(request.headers.value('X-Emby-Token'), isNull);
      expect(request.headers.value('X-Emby-Authorization'), isNull);
      final match = RegExp(
        r'^bytes=(\d+)-(\d*)$',
      ).firstMatch(request.headers.value('range') ?? '')!;
      final start = int.parse(match[1]!);
      final end = match[2]!.isEmpty ? total - 1 : int.parse(match[2]!);
      final response = request.response;
      if (redirectTail && start == total - 64) {
        response.statusCode = 302;
        response.headers.set(
          'Location',
          'http://127.0.0.1:${entry.port}/emby/Videos/1/stream',
        );
        response.contentLength = 0;
        await response.close();
        return;
      }
      response.statusCode = 206;
      response.contentLength = end - start + 1;
      response.headers.set('Accept-Ranges', 'bytes');
      response.headers.set('Content-Range', 'bytes $start-$end/$total');
      if (strongTag) {
        response.headers.set(
          'ETag',
          changedTail && start == total - 64
              ? '"synthetic-changed-148"'
              : '"synthetic-fixed-148"',
        );
      }
      response.headers.contentType = ContentType.binary;
      if (start == resume) {
        resumedBodies++;
        await coldGate.future;
      }
      final count = (end - start + 1).clamp(0, 512 * 1024);
      response.add(
        Uint8List.fromList([for (var i = 0; i < count; i++) (start + i) % 251]),
      );
      await response.flush();
      if (end - start + 1 > count) await bodyGate.future;
      await response.close();
    } catch (error) {
      if (error is TestFailure) rethrow;
      // Intentional cancellation of an unfinished synthetic response.
    }
  });
  entry.listen((request) async {
    entryCalls++;
    expect(request.headers.value('X-Emby-Token'), 'SYNTHETIC_TOKEN');
    request.response.statusCode = 302;
    request.response.headers.set(
      'Location',
      'http://127.0.0.1:${upstream.port}/media.bin?sig=A%2fB&x=1&x=2',
    );
    request.response.contentLength = 0;
    await request.response.close();
  });
  Future<List<int>> prefix(
    String address,
    int start,
    int count, {
    int status = 206,
  }) async {
    final client = HttpClient()..autoUncompress = false;
    clients.add(client);
    try {
      final request = await client.getUrl(Uri.parse(address));
      request.headers.set(
        'Range',
        'bytes=$start-${start == total - 64 ? total - 1 : ''}',
      );
      final response = await request.close();
      expect(response.statusCode, status);
      if (status != 206) {
        await response.drain<void>();
        return [];
      }
      final iterator = StreamIterator(response);
      final data = <int>[];
      while (data.length < count && await iterator.moveNext()) {
        data.addAll(iterator.current.take(count - data.length));
      }
      await iterator.cancel();
      expect(data, [for (var i = 0; i < count; i++) (start + i) % 251]);
      return data;
    } finally {
      client.close(force: true);
      clients.remove(client);
    }
  }

  try {
    final address = await wrap(await origin.start());
    await prefix(address, 0, 512 * 1024);
    await prefix(
      address,
      total - 64,
      64,
      status: changedTail || redirectTail ? 502 : 206,
    );
    if (changedTail || redirectTail) {
      return (
        entryCalls: entryCalls,
        resumedBodies: resumedBodies,
        upstreamRequests: upstreamRequests,
        available: false,
      );
    }
    final resumed = prefix(address, resume, 64 * 1024);
    final available = await resumed
        .then((_) => true)
        .timeout(const Duration(milliseconds: 200), onTimeout: () => false);
    coldGate.complete();
    await resumed;
    return (
      entryCalls: entryCalls,
      resumedBodies: resumedBodies,
      upstreamRequests: upstreamRequests,
      available: available,
    );
  } finally {
    if (!coldGate.isCompleted) coldGate.complete();
    if (!bodyGate.isCompleted) bodyGate.complete();
    for (final client in clients) {
      client.close(force: true);
    }
    await origin.close();
    await entry.close(force: true);
    await upstream.close(force: true);
  }
}

void main() {
  test(
    'bridge TLS incompatibility leaves native certificate policy and target unchanged',
    () => HttpOverrides.runWithHttpOverrides(() async {
      const target = 'https://synthetic.invalid/movie.mp4?sig=A%2fB';
      final transport = StartupPlaybackTransport(
        address: target,
        headers: const {},
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        request.followRedirects = false;
        final response = await request.close();
        expect(response.statusCode, 307);
        expect(response.headers.value('location'), target);
        expect(transport.failure, isNull);
        await response.drain<void>();
      } finally {
        client.close(force: true);
        await transport.close();
      }
    }, _HandshakeOverrides()),
  );
  test(
    'upstream error responses are forwarded once and do not become cookie or XML retries',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = StartupPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/failed.mp4',
        headers: const {},
      );
      final client = HttpClient();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = 502;
        request.response.cookies.add(Cookie('synthetic_error', 'FIXTURE'));
        request.response.write('<?xml version="1.0"?><error/>');
        await request.response.close();
      });
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        final response = await request.close();
        expect(response.statusCode, 502);
        expect(response.redirects, isEmpty);
        await response.drain<void>();
        expect(requests, 1);
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'a later redirect never revisits the protected media entry',
    () => HttpOverrides.runWithHttpOverrides(() async {
      StartupPlaybackTransport? transport;
      try {
        final result = await startupProbe((address) async {
          transport = StartupPlaybackTransport(
            address: address,
            headers: const {},
          );
          return transport!.start();
        }, redirectTail: true);
        expect(result.entryCalls, 1);
        expect(result.upstreamRequests, 2);
        expect(transport!.failure, contains('已解析的媒体地址发生跳转'));
      } finally {
        await transport?.close();
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'a real distant seek leaves startup buffering and uses the exact requested bytes',
    () => HttpOverrides.runWithHttpOverrides(() async {
      StartupPlaybackTransport? transport;
      try {
        final result = await startupProbe((address) async {
          transport = StartupPlaybackTransport(
            address: address,
            headers: const {},
          );
          return transport!.start();
        }, resume: 12 * 1024 * 1024);
        expect(result.entryCalls, 1);
        expect(result.resumedBodies, 1);
        expect(transport!.reusedBytes, 0);
        expect(transport!.retainedBytes, 0);
      } finally {
        await transport?.close();
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'server cookies remain attached to the real native URL rather than loopback',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final address = 'http://127.0.0.1:${server.port}/cookie.mp4';
      final transport = StartupPlaybackTransport(
        address: address,
        headers: const {},
      );
      final client = HttpClient();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.cookies.add(
          Cookie('synthetic_media', 'FIXTURE')..path = '/',
        );
        request.response.add([1, 2, 3, 4]);
        await request.response.close();
      });
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        final response = await request.close();
        expect(response.redirects.last.location.toString(), address);
        expect(
          response.cookies.map((c) => c.name),
          contains('synthetic_media'),
        );
        expect(await response.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
          4,
        ]);
        expect(requests, 2);
        expect(transport.peakBytes, 0);
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'native conditional request headers survive the startup bridge',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = StartupPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/condition.mp4',
        headers: const {},
      );
      final client = HttpClient();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode =
            request.headers.value('if-match') == '"CONDITION"' ? 304 : 412;
        request.response.contentLength = 0;
        await request.response.close();
      });
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        request.headers.set('If-Match', '"CONDITION"');
        final response = await request.close();
        expect(response.statusCode, 304);
        await response.drain<void>();
        expect(requests, 1);
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'short upstream bodies remain failures rather than a fabricated clean EOF',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = StartupPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/short.mp4',
        headers: const {},
      );
      final client = HttpClient();
      server.listen((request) async {
        try {
          request.response.statusCode = 206;
          request.response.contentLength = 32 * 1024 * 1024;
          request.response.headers.set(
            'Content-Range',
            'bytes 0-33554431/33554432',
          );
          request.response.headers.set('ETag', '"short148"');
          request.response.add(Uint8List(8192));
          await request.response.close();
        } catch (_) {}
      });
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        request.headers.set('Range', 'bytes=0-');
        var failed = false;
        try {
          final response = await request.close();
          failed = response.statusCode >= 400;
          await response.drain<void>();
        } catch (_) {
          failed = true;
        }
        expect(failed, isTrue);
        expect(transport.failure, isNotNull);
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'old direct startup reopens the body after the tiny tail probe',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final result = await startupProbe((address) async => address);
      expect(result.entryCalls, 1);
      expect(result.resumedBodies, 1);
      expect(result.upstreamRequests, 3);
      expect(result.available, isFalse);
    }, LoopbackHttpOverrides()),
  );
  test(
    'validated startup reuses the original body across the tail probe',
    () => HttpOverrides.runWithHttpOverrides(() async {
      StartupPlaybackTransport? transport;
      try {
        final result = await startupProbe((address) async {
          transport = StartupPlaybackTransport(
            address: address,
            headers: const {'User-Agent': 'Yingyu-test'},
          );
          return transport!.start();
        });
        expect(result.entryCalls, 1);
        expect(result.resumedBodies, 0);
        expect(result.upstreamRequests, 2);
        expect(result.available, isTrue);
        expect(transport!.openedResponses, 2);
        expect(transport!.peakResponses, lessThanOrEqualTo(2));
        expect(
          transport!.peakBytes,
          lessThanOrEqualTo(StartupPlaybackTransport.maxBytes),
        );
        expect(transport!.reusedBytes, greaterThanOrEqualTo(64 * 1024));
      } finally {
        await transport?.close();
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'missing strong identity keeps native ranges without an extra upstream probe',
    () => HttpOverrides.runWithHttpOverrides(() async {
      StartupPlaybackTransport? transport;
      try {
        final result = await startupProbe((address) async {
          transport = StartupPlaybackTransport(
            address: address,
            headers: const {},
          );
          return transport!.start();
        }, strongTag: false);
        expect(result.entryCalls, 1);
        expect(result.upstreamRequests, 3);
        expect(result.resumedBodies, 1);
        expect(transport!.reusedBytes, 0);
        expect(transport!.peakBytes, 0);
      } finally {
        await transport?.close();
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'a changed tail identity is rejected before cached bytes are reused',
    () => HttpOverrides.runWithHttpOverrides(() async {
      StartupPlaybackTransport? transport;
      try {
        final result = await startupProbe((address) async {
          transport = StartupPlaybackTransport(
            address: address,
            headers: const {},
          );
          return transport!.start();
        }, changedTail: true);
        expect(result.resumedBodies, 0);
        expect(transport!.failure, contains('文件校验或字节范围发生变化'));
        expect(transport!.reusedBytes, 0);
      } finally {
        await transport?.close();
      }
    }, LoopbackHttpOverrides()),
  );
  test('only file-shaped MP4 family entries are startup candidates', () {
    for (final value in [
      'https://example.test/stream.mp4?x=1',
      'https://example.test/A.MOV',
      'https://example.test/a.m4v',
    ]) {
      expect(startupRangeCandidate(value), isTrue);
    }
    for (final value in [
      'https://example.test/a.m3u8',
      'https://example.test/a.mpd',
      'https://example.test/a.iso',
      'https://example.test/download?name=a.mp4',
    ]) {
      expect(startupRangeCandidate(value), isFalse);
    }
  });
  test(
    'an unexpected playlist retains the original URL for relative segments',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final address = 'http://127.0.0.1:${server.port}/movie.mp4';
      final transport = StartupPlaybackTransport(
        address: address,
        headers: const {},
      );
      final client = HttpClient();
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType.binary;
        request.response.write('#EXTM3U\nsegment.ts\n');
        await request.response.close();
      });
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        final response = await request.close();
        expect(response.redirects.last.location.toString(), address);
        expect(
          response.redirects.last.location.resolve('segment.ts').port,
          server.port,
        );
        expect(
          await response.fold<List<int>>([], (a, b) => a..addAll(b)),
          isNotEmpty,
        );
        expect(requests, 2);
        expect(transport.peakBytes, 0);
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
  test(
    'continuous fast-start data crosses the startup budget and closes without deadlock',
    () => HttpOverrides.runWithHttpOverrides(() async {
      const total = 32 * 1024 * 1024;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final transport = StartupPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/movie.mp4',
        headers: const {},
      );
      final client = HttpClient();
      var requests = 0;
      server.listen((request) async {
        requests++;
        try {
          request.response.statusCode = 206;
          request.response.contentLength = total;
          request.response.headers.set(
            'Content-Range',
            'bytes 0-${total - 1}/$total',
          );
          request.response.headers.set('ETag', '"continuous148"');
          for (var page = 0; page < total ~/ 65536; page++) {
            final data = Uint8List(65536);
            ByteData.sublistView(data).setUint32(0, page, Endian.little);
            request.response.add(data);
            await request.response.flush();
          }
          await request.response.close();
        } catch (_) {
          /* Intentional close after the tested byte prefix. */
        }
      });
      try {
        final request = await client.getUrl(Uri.parse(await transport.start()));
        request.headers.set('Range', 'bytes=0-');
        final response = await request.close();
        var received = 0;
        await for (final data in response.timeout(const Duration(seconds: 5))) {
          for (final value in data) {
            final offset = received % 65536;
            final expected = offset < 4
                ? ((received ~/ 65536) >> (8 * offset)) & 255
                : 0;
            if (value != expected) {
              fail('byte mismatch at $received');
            }
            received++;
          }
          if (received >= 16 * 1024 * 1024) break;
        }
        expect(received, greaterThanOrEqualTo(16 * 1024 * 1024));
        expect(requests, 1);
        expect(
          transport.peakBytes,
          lessThanOrEqualTo(StartupPlaybackTransport.maxBytes),
        );
        await transport.close().timeout(const Duration(seconds: 2));
        expect(transport.retainedBytes, 0);
      } finally {
        client.close(force: true);
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides()),
  );
}
