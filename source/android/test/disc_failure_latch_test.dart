import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final status in [408, 500, 502, 504]) {
    test(
      'disc parser repeat reads after HTTP $status make one upstream attempt',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          var attempts = 0;
          origin.listen((request) async {
            attempts++;
            request.response.statusCode = status;
            request.response.write(
              '<html><title>Gateway unavailable</title></html>',
            );
            await request.response.close();
          });
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            (call) async {
              if (call.method != 'open') return null;
              final client = HttpClient();
              try {
                // Simulate VideoLAN's repeated sector probes, without loading JNI.
                for (var i = 0; i < 8; i++) {
                  final request = await client.getUrl(
                    Uri.parse('${call.arguments['base']}/input?path='),
                  );
                  request.headers.set('Range', 'bytes=0-1048575');
                  final response = await request.close();
                  expect(response.statusCode, i == 0 ? status : 502);
                  await response.drain<void>();
                }
              } finally {
                client.close(force: true);
              }
              throw PlatformException(
                code: 'disc',
                message: 'No readable title',
              );
            },
          );
          final transport = DiscTransport(
            route('http://127.0.0.1:${origin.port}/stream'),
            kind: DiscKind.iso,
          );
          try {
            await expectLater(
              transport.start(),
              throwsA(
                isA<AppFailure>().having(
                  (e) => e.toString(),
                  'cause',
                  contains('HTTP $status'),
                ),
              ),
            );
            expect(
              attempts,
              1,
              reason:
                  '502 and other server failures must not trigger a sector-probe request storm',
            );
            expect(transport.failure, contains('Gateway unavailable'));
          } finally {
            await transport.close();
            await origin.close(force: true);
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
