import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'package:yingyu/core/models.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final rejected in [false, true]) {
    test(
      'concurrent ordinary STRM requests join one entry attempt rejected=$rejected',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = Uri.parse('http://127.0.0.1:${server.port}');
        var entries = 0;
        server.listen((req) async {
          entries++;
          await Future<void>.delayed(const Duration(milliseconds: 60));
          req.response.statusCode = rejected ? 403 : 302;
          if (!rejected) {
            req.response.headers.set(
              'Location',
              'https://synthetic.invalid/video.mkv?sig=%2f',
            );
          }
          await req.response.close();
        });
        final transport = EmbyOriginTransport(
          route('$origin/stream', origin: origin, kind: DiscKind.none),
        );
        final client = HttpClient();
        try {
          final address = Uri.parse(await transport.start());
          await Future.wait(
            List.generate(5, (i) async {
              final req = await client.getUrl(address);
              req.followRedirects = false;
              req.headers.set('Range', 'bytes=${i * 100}-');
              final response = await req.close();
              expect(response.statusCode, rejected ? anyOf(403, 502) : 302);
              await response.drain<void>();
            }),
          );
          final retry = await client.getUrl(address);
          retry.followRedirects = false;
          await (await retry.close()).drain<void>();
          expect(entries, 1);
        } finally {
          client.close(force: true);
          await transport.close();
          await server.close(force: true);
        }
      }, LoopbackHttpOverrides()),
    );
  }

  test(
    'ISO concurrent metadata and later seeks use one STRM entry',
    () => HttpOverrides.runWithHttpOverrides(() async {
      const mib = 1024 * 1024, total = 64 * mib;
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final cloud = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final base = Uri.parse('http://127.0.0.1:${origin.port}');
      var entries = 0;
      final ranges = <String>[];
      origin.listen((req) async {
        entries++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        req.response.statusCode = 302;
        req.response.headers.set(
          'Location',
          'http://127.0.0.1:${cloud.port}/disc.iso?sign=%2f',
        );
        await req.response.close();
      });
      cloud.listen((req) async {
        try {
          expect(req.headers.value('x-emby-token'), null);
          final range = discByteRange(req.headers.value('range'), total)!;
          ranges.add(req.headers.value('range')!);
          req.response.statusCode = 206;
          req.response.contentLength = range.end - range.start + 1;
          req.response.headers.set(
            'Content-Range',
            'bytes ${range.start}-${range.end}/$total',
          );
          for (var start = range.start; start <= range.end; start += mib) {
            final length = (range.end - start + 1).clamp(0, mib);
            req.response.add(Uint8List(length));
            await req.response.flush();
          }
          await req.response.close();
        } on HttpException {
          /* expected seek cancellation */
        } on SocketException {
          /* expected seek cancellation */
        }
      });
      final client = HttpClient();
      Future<void> read(String local, int start) async {
        final req = await client.getUrl(Uri.parse('$local/input?path='));
        req.headers.set('Range', 'bytes=$start-${start + 15}');
        final response = await req.close();
        expect(response.statusCode, 206);
        expect(await response.fold<int>(0, (n, b) => n + b.length), 16);
      }

      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DiscTransport.channel,
        (call) async {
          if (call.method != 'open') return null;
          final local = call.arguments['base'] as String;
          await Future.wait([read(local, 0), read(local, 2048)]);
          return titleData;
        },
      );
      final transport = DiscTransport(
        route('$base/strm-entry', origin: base),
        kind: DiscKind.iso,
      );
      try {
        await transport.start();
        await read(transport.base, 4 * mib);
        // A small input can now return before its 4 MiB block is complete.
        // Finish the block before asserting completed-cache reuse after seek;
        // obsolete partial-tail cancellation is checked separately.
        await read(transport.base, 8 * mib - 16);
        transport.resetReadAhead();
        await read(transport.base, 48 * mib);
        await read(transport.base, 4 * mib);
        expect(entries, 1);
        expect(ranges, [
          'bytes=0-15',
          'bytes=2048-2063',
          'bytes=4194304-',
          'bytes=50331648-',
        ]);
      } finally {
        await transport.close();
        client.close(force: true);
        await origin.close(force: true);
        await cloud.close(force: true);
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          null,
        );
      }
    }, LoopbackHttpOverrides()),
  );
}
