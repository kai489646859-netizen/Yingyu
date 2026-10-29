import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/subtitle_files.dart';

PlaybackRoute route(String url, {Uri? origin}) => PlaybackRoute(
  url: url,
  sourceId: 'synthetic',
  sessionId: 'synthetic',
  headers: const {},
  streams: const [],
  serverBase: origin,
  sameOriginHeaders: const {'X-Emby-Token': 'synthetic-token'},
);

void main() {
  test(
    'selected subtitle uses origin auth; signed redirect is exact and never receives auth',
    () async {
      final emby = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final external = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => emby.close(force: true));
      addTearDown(external.close);
      var entries = 0, files = 0;
      String? auth, outside;
      String? requestTarget;
      external.listen((socket) {
        var request = '';
        socket.listen((data) async {
          request += ascii.decode(data);
          if (!request.contains('\r\n\r\n')) return;
          files++;
          outside = request.toLowerCase().contains('x-emby-token')
              ? 'leaked'
              : null;
          requestTarget = request.split(' ')[1];
          final body = utf8.encode('1\n00:00:01,000 --> 00:00:02,000\n合成字幕\n');
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
            ),
          );
          socket.add(body);
          await socket.flush();
          await socket.close();
        });
      });
      emby.listen((r) async {
        entries++;
        auth = r.headers.value('x-emby-token');
        r.response.statusCode = 302;
        r.response.headers.set(
          'Location',
          'http://127.0.0.1:${external.port}/sub%2fass?s=%7e%2b+',
        );
        await r.response.close();
      });
      final origin = Uri.parse('http://127.0.0.1:${emby.port}');
      final cache = SubtitleFiles();
      addTearDown(cache.close);
      final source = route('$origin/subtitle', origin: origin);
      final results = await Future.wait([
        cache.load('sub-1', source, 'srt'),
        cache.load('sub-1', source, 'srt'),
      ]);
      expect(results[0].path, results[1].path);
      expect(await results[0].readAsString(), contains('合成字幕'));
      await cache.load('sub-1', source, 'srt');
      expect(entries, 1);
      expect(files, 1);
      expect(auth, 'synthetic-token');
      expect(outside, isNull);
      expect(requestTarget, '/sub%2fass?s=%7e%2b+');
      final parent = results[0].parent;
      await cache.close();
      expect(await parent.exists(), isFalse);
    },
  );
  test(
    'HTTP failure is returned without MPV, media requests, or automatic retry',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var count = 0;
      server.listen((r) async {
        count++;
        r.response.statusCode = 403;
        await r.response.close();
      });
      final cache = SubtitleFiles();
      addTearDown(cache.close);
      await expectLater(
        cache.load(
          'sub',
          route('http://127.0.0.1:${server.port}/subtitle'),
          'srt',
        ),
        throwsA(
          isA<AppFailure>().having((e) => e.status, 'actual status', 403),
        ),
      );
      expect(count, 1);
    },
  );
  test(
    'streamed size bound and close cancellation remove partial subtitle files',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((r) async {
        r.response.add(List.filled(32, 65));
        await r.response.close();
      });
      final cache = SubtitleFiles(maxBytes: 16);
      addTearDown(cache.close);
      await expectLater(
        cache.load(
          'sub',
          route('http://127.0.0.1:${server.port}/subtitle'),
          'srt',
        ),
        throwsA(isA<AppFailure>()),
      );
      cache.cancel();
      await expectLater(
        cache.load(
          'sub',
          route('http://127.0.0.1:${server.port}/subtitle'),
          'srt',
        ),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test('same URL redirect loop stops before a second entry request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var count = 0;
    server.listen((r) async {
      count++;
      r.response.statusCode = 302;
      r.response.headers.set('location', '/subtitle');
      await r.response.close();
    });
    final cache = SubtitleFiles();
    addTearDown(cache.close);
    await expectLater(
      cache.load(
        'sub',
        route('http://127.0.0.1:${server.port}/subtitle'),
        'srt',
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(count, 1);
  });
  test(
    'slow chosen subtitle can be cancelled without leaving a pending operation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final entered = Completer<void>();
      server.listen((r) {
        entered.complete();
      });
      final cache = SubtitleFiles();
      final pending = cache.load(
        'sub',
        route('http://127.0.0.1:${server.port}/subtitle'),
        'srt',
      );
      final failed = expectLater(pending, throwsA(isA<AppFailure>()));
      await entered.future;
      await cache.close().timeout(const Duration(seconds: 3));
      await failed;
    },
  );
}
