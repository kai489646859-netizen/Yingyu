import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/disc_buffering.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const mib = 1024 * 1024;
  test(
    'speed cache growth stays within current device memory tier and restores normal budget',
    () {
      expect(discForwardBufferBytes(32 * mib, 3, 32), 32 * mib);
      expect(discForwardBufferBytes(64 * mib, 3, 32), 64 * mib);
      expect(discForwardBufferBytes(64 * mib, 3, 64), 384 * mib);
      expect(discForwardBufferBytes(128 * mib, 3, 128), 768 * mib);
      expect(discForwardBufferBytes(64 * mib, 1.25, 64), 120 * mib);
      for (final speed in [.5, 1.0]) {
        expect(discForwardBufferBytes(64 * mib, speed, 128), 64 * mib);
      }
      expect(
        discForwardBufferBytes(128 * mib, 1, 128, previousBytes: 512 * mib),
        512 * mib,
      );
      expect(
        discForwardBufferBytes(128 * mib, 1, 32, previousBytes: 512 * mib),
        128 * mib,
      );
      expect(discForwardBufferBytes(128 * mib, 2, 128), 384 * mib);
    },
  );
  for (final speed in [1.0, 1.5, 3.0]) {
    test(
      'local clip delivery uses bounded batches at $speed without reading a media server',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          var reads = 0;
          const length = 4 * mib + 123;
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            (call) async {
              if (call.method == 'open') return titleData;
              if (call.method == 'size') return length;
              if (call.method == 'read') {
                reads++;
                final count = call.arguments['length'] as int;
                final offset = call.arguments['offset'] as int;
                expect(count, lessThanOrEqualTo(mib));
                return Uint8List.fromList(
                  List.generate(count, (i) => (offset + i) % 251),
                );
              }
              return null;
            },
          );
          final transport = DiscTransport(
            route('http://127.0.0.1:9/synthetic-only.iso'),
            kind: DiscKind.iso,
          );
          final client = HttpClient();
          try {
            await transport.start();
            transport.setSpeed(speed);
            final request = await client.getUrl(
              Uri.parse('${transport.base}/clip/00001.m2ts'),
            );
            final response = await request.close();
            expect(response.statusCode, 200);
            var received = 0;
            await for (final chunk in response) {
              for (var i = 0; i < chunk.length; i++) {
                if (chunk[i] != (received + i) % 251) {
                  fail('Byte order changed at ${received + i}');
                }
              }
              received += chunk.length;
            }
            expect(received, length);
            expect(
              reads,
              speed == 1
                  ? 17
                  : speed == 1.5
                  ? 9
                  : 5,
            );
            expect(transport.failure, null);
          } finally {
            client.close(force: true);
            await transport.close();
            binding.defaultBinaryMessenger.setMockMethodCallHandler(
              DiscTransport.channel,
              null,
            );
          }
        }, LoopbackHttpOverrides());
      },
    );
  }
}
