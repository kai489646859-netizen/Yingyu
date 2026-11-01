import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/subtitle_files.dart';
import 'subtitle_files_test.dart' show route;

void main() {
  test('relative subtitle redirect preserves signed target bytes', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    final targets = <String>[];
    server.listen((socket) {
      sockets.add(socket);
      var header = '', replied = false;
      socket.listen((bytes) async {
        header += latin1.decode(bytes);
        if (replied || !header.contains('\r\n\r\n')) return;
        replied = true;
        final target = header.split(' ')[1];
        targets.add(target);
        if (target == '/entry') {
          socket.add(
            ascii.encode(
              'HTTP/1.1 302 Found\r\nLocation: /sub%2fass?sig=a%2fb&x=1&x=2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
            ),
          );
        } else {
          socket.add(
            ascii.encode(
              'HTTP/1.1 200 OK\r\nContent-Length: 3\r\nConnection: close\r\n\r\nsub',
            ),
          );
        }
        await socket.flush();
        await socket.close();
      }, onError: (Object _) {});
    });
    final cache = SubtitleFiles();
    try {
      final file = await cache.load(
        'signed',
        route('http://127.0.0.1:${server.port}/entry'),
        'srt',
      );
      expect(await file.readAsString(), 'sub');
      expect(targets, ['/entry', '/sub%2fass?sig=a%2fb&x=1&x=2']);
    } finally {
      await cache.close();
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    }
  });

  test(
    'concurrent subtitle downloads share the total 128 MiB budget',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gate = Completer<void>();
      var bodies = 0;
      final chunk = Uint8List(64 * 1024);
      final serving = <Future<void>>[];
      server.listen((request) {
        serving.add(() async {
          try {
            final chunks = request.uri.path == '/retry'
                ? int.parse(request.uri.queryParameters['chunks']!)
                : 720;
            for (var i = 0; i < chunks; i++) {
              request.response.add(chunk);
              await request.response.flush();
            }
          } catch (_) {
            // A rejected client may close while the synthetic server is writing.
          } finally {
            if (++bodies == 3) gate.complete();
            await gate.future;
            // Delay the final chunked terminator so concurrent consumers receive
            // their bodies before any one response becomes a completed file.
            await Future<void>.delayed(const Duration(milliseconds: 250));
            try {
              await request.response.close();
            } catch (_) {}
          }
        }());
      });
      final cache = SubtitleFiles(timeout: const Duration(seconds: 60));
      try {
        final results = await Future.wait([
          for (var i = 0; i < 3; i++)
            cache
                .load('$i', route('http://127.0.0.1:${server.port}/$i'), 'srt')
                .then<Object>((file) => file, onError: (Object error) => error),
        ]);
        var retained = 0;
        for (final file in results.whereType<File>()) {
          retained += await file.length();
        }
        expect(retained, lessThanOrEqualTo(128 * 1024 * 1024));
        expect(results.whereType<AppFailure>(), isNotEmpty);
        // Failed partial files release their reservations. The next successful
        // track may fill the remaining quota exactly, not just stop below it.
        var attempt = 0;
        while (retained < 128 * 1024 * 1024) {
          final remaining = (128 * 1024 * 1024 - retained) ~/ chunk.length;
          final chunks = remaining.clamp(1, 1024);
          final retry = await cache.load(
            'retry${attempt++}',
            route('http://127.0.0.1:${server.port}/retry?chunks=$chunks'),
            'srt',
          );
          retained += await retry.length();
        }
        expect(retained, 128 * 1024 * 1024);
        await expectLater(
          cache.load(
            'overflow',
            route('http://127.0.0.1:${server.port}/retry?chunks=1'),
            'srt',
          ),
          throwsA(isA<AppFailure>()),
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
        await cache.close();
        await server.close(force: true);
        await Future.wait(serving);
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
