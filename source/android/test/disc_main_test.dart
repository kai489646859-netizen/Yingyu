import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DiscTransport.channel,
      null,
    ),
  );

  test(
    'upstream 403 remains the root error when native read returns empty bytes',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        source.listen((request) async {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            '{"status":403,"message":"synthetic media denied"}',
          );
          await request.response.close();
        });
        final client = HttpClient();
        final failures = <String>[];
        final transport = DiscTransport(
          route('http://127.0.0.1:${source.port}/film.iso'),
          kind: DiscKind.iso,
          onFailure: failures.add,
        );
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            if (call.method == 'open') return titleData;
            if (call.method == 'size') return 1024;
            if (call.method == 'read') {
              final read = await client.getUrl(
                Uri.parse('${transport.base}/input'),
              );
              read.headers.set('Range', 'bytes=0-1023');
              final result = await read.close();
              expect(result.statusCode, 502);
              await result.drain<void>();
              return Uint8List(0);
            }
            return null;
          },
        );
        try {
          await transport.start();
          try {
            final response = await (await client.getUrl(
              Uri.parse('${transport.base}/clip/00001.m2ts'),
            )).close();
            await response.drain<void>();
          } on HttpException {
            /* local response interrupted */
          }
          expect(failures, hasLength(1));
          expect(failures.single, contains('HTTP 403'));
          expect(failures.single, contains('synthetic media denied'));
          expect(failures.single, isNot(contains('原盘片段提前结束')));
        } finally {
          client.close(force: true);
          await transport.close();
          await source.close(force: true);
        }
      }, LoopbackHttpOverrides());
    },
  );

  test(
    'VideoLAN main title wins over duration; explicit selection is preserved',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            if (call.method != 'open') return null;
            return jsonEncode([
              {
                'playlist': 1,
                'duration': 18000000,
                'clips': [
                  {'id': '00001', 'in': 0, 'out': 18000000},
                ],
              },
              {
                'playlist': 2,
                'main': true,
                'duration': 9000000,
                'clips': [
                  {'id': '00002', 'in': 0, 'out': 9000000},
                ],
              },
            ]);
          },
        );
        for (final explicit in [null, 1]) {
          final transport = DiscTransport(
            route('https://unused.invalid/disc.iso'),
            kind: DiscKind.iso,
          );
          try {
            final edl = await transport.start(playlist: explicit);
            expect(transport.selected!.playlist, explicit ?? 2);
            expect(
              edl,
              contains(explicit == null ? '00002.m2ts' : '00001.m2ts'),
            );
          } finally {
            await transport.close();
          }
        }
      }, LoopbackHttpOverrides());
    },
  );

  test(
    'new GET cancels superseded range, but HEAD does not interrupt reading',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        const chunk = 256 * 1024, size = 8 * 1024 * 1024;
        final reading = Completer<void>(), gate = Completer<void>();
        final reads = <int>[];
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            if (call.method == 'open') return titleData;
            if (call.method == 'size') return size;
            if (call.method == 'read') {
              final args = call.arguments as Map;
              final offset = args['offset'] as int,
                  length = args['length'] as int;
              reads.add(offset);
              if (offset == chunk) {
                reading.complete();
                await gate.future;
              }
              return Uint8List.fromList(
                List.generate(length, (i) => (offset + i) % 251),
              );
            }
            return null;
          },
        );
        final failures = <String>[];
        final transport = DiscTransport(
          route('https://unused.invalid/disc.iso'),
          kind: DiscKind.iso,
          onFailure: failures.add,
        );
        final client = HttpClient();
        try {
          await transport.start();
          final uri = Uri.parse('${transport.base}/clip/00001.m2ts');
          var initialEnded = false;
          final initial = (await client.getUrl(uri))
              .close()
              .then((r) => r.drain<void>())
              .catchError((Object _) {})
              .whenComplete(() => initialEnded = true);
          await reading.future.timeout(const Duration(seconds: 3));
          final head = await (await client.headUrl(uri)).close();
          expect(head.statusCode, 200);
          await head.drain<void>();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            initialEnded,
            false,
            reason: 'HEAD must not cancel the playback response',
          );
          final seekRequest = await client.getUrl(uri);
          seekRequest.headers.set('Range', 'bytes=${size - 1024}-${size - 1}');
          final seekResponse = await seekRequest.close();
          final received = await seekResponse.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          );
          expect(received, List.generate(1024, (i) => (size - 1024 + i) % 251));
          gate.complete();
          await initial.timeout(const Duration(seconds: 3));
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(reads, [0, chunk, size - 1024]);
          expect(failures, isEmpty);
          expect(transport.failure, null);
        } finally {
          if (!gate.isCompleted) gate.complete();
          client.close(force: true);
          await transport.close();
        }
      }, LoopbackHttpOverrides());
    },
  );
}
