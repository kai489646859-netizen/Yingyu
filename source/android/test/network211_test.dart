import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/byte_cache.dart';
import 'package:yingyu/playback/cached_transport.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'core_test.dart' show LoopbackHttpOverrides;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    '302 entry visited once; interrupted validated body resumes exact bytes',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final data = Uint8List.fromList(List.generate(524288, (i) => i % 251));
      var entries = 0;
      final ranges = <int>[];
      final targets = <String>[];
      final sockets = <Socket>[];
      server.listen((socket) {
        sockets.add(socket);
        var header = '', replied = false;
        socket.listen((bytes) async {
          header += latin1.decode(bytes);
          if (replied || !header.contains('\r\n\r\n')) return;
          replied = true;
          final target = header.split(' ')[1];
          if (target == '/entry') {
            entries++;
            socket.add(
              ascii.encode(
                'HTTP/1.1 302 Found\r\nLocation: /cloud?sig=a%2fb&x=1&x=2\r\nContent-Length: 0\r\nConnection: close\r\n\r\n',
              ),
            );
          } else {
            targets.add(target);
            final start = int.parse(
              RegExp(r'bytes=(\d+)-').firstMatch(header)![1]!,
            );
            ranges.add(start);
            socket.add(
              ascii.encode(
                'HTTP/1.1 206 Partial Content\r\nETag: "same"\r\nContent-Range: bytes $start-${data.length - 1}/${data.length}\r\nContent-Length: ${data.length - start}\r\nConnection: close\r\n\r\n',
              ),
            );
            socket.add(
              data.sublist(start, ranges.length == 1 ? 65536 : data.length),
            );
          }
          await socket.flush();
          await socket.close();
        }, onError: (Object _) {});
      });
      final transport = CachedPlaybackTransport(
        address: 'http://127.0.0.1:${server.port}/entry',
        headers: {},
        cache: PlaybackByteCache(),
        scope: 'synthetic',
      );
      try {
        final got = await transport.reader.read(
          0,
          data.length,
          DiscReadCancellation(),
        );
        expect(got, data);
        expect(entries, 1);
        expect(ranges, [0, 65536]);
        expect(targets, everyElement('/cloud?sig=a%2fb&x=1&x=2'));
      } finally {
        await transport.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await server.close();
      }
    }, LoopbackHttpOverrides()),
  );
}
