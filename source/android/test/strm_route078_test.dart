import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'package:yingyu/playback/dolby_source.dart';
import 'core_test.dart' show response, syntheticSession, LoopbackHttpOverrides;
import 'startup_test.dart' show sourceFor, detailFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final extension in ['mkv', 'iso']) {
    test(
      'incomplete remote $extension uses fresh negotiated entry and one media request',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final base = 'http://127.0.0.1:${server.port}';
          var metadata = 0, media = 0, fabricated = 0;
          final bytes = List.generate(4096, (i) => i % 251);
          server.listen((request) async {
            if (request.uri.path != '/fresh.$extension') {
              fabricated++;
              request.response.statusCode = 503;
            } else {
              media++;
              expect(request.uri.query, 'signature=a%2Fb%2Bc&part=1&part=2');
              expect(request.headers.value('x-emby-token'), isNull);
              expect(
                request.headers.value('referer'),
                'https://required.invalid/',
              );
              request.response.statusCode = 206;
              request.response.headers.set(
                'Content-Range',
                'bytes 0-4095/4096',
              );
              request.response.contentLength = bytes.length;
              request.response.add(bytes);
            }
            await request.response.close();
          });
          final api = EmbyClient(
            client: MockClient((request) async {
              metadata++;
              expect(request.url.path, endsWith('/PlaybackInfo'));
              expect(jsonDecode(request.body)['EnableTranscoding'], false);
              return response(
                jsonEncode({
                  'PlaySessionId': 'fresh',
                  'MediaSources': [
                    {
                      ...sourceFor(extension),
                      'DirectStreamUrl':
                          '$base/fresh.$extension?signature=a%2fb%2Bc&part=1&part=2',
                      'RequiredHttpHeaders': {
                        'Referer': 'https://required.invalid/',
                      },
                    },
                  ],
                }),
                200,
              );
            }),
          )..session = syntheticSession(base);
          EmbyOriginTransport? origin;
          DiscTransport? disc;
          final client = HttpClient();
          try {
            final route = await api.preparePlayback(
              detailFor({
                ...sourceFor(extension),
                'Protocol': 'Http',
                'SupportsDirectPlay': true,
                'Path': '$base/stale.$extension',
                // Without the required-header facts this source still needs
                // negotiation; complete static HTTP sources are covered by
                // static_original080_test.dart instead.
                'RequiredHttpHeaders': null,
              }),
            );
            expect(metadata, 1);
            expect(
              route.url,
              '$base/fresh.$extension?signature=a%2fb%2Bc&part=1&part=2',
            );
            if (extension == 'iso') {
              disc = DiscTransport(
                route,
                kind: DiscKind.iso,
                directInput: true,
                nativeInvoke: (_, _) async => null,
              );
              final block = await disc.readNativeInput(
                1,
                '',
                0,
                4096,
                DiscReadCancellation(),
              );
              expect(block!.bytes, bytes);
            } else {
              var address = route.url;
              if (route.sameOriginHeaders.isNotEmpty) {
                origin = EmbyOriginTransport(route);
                address = await origin.start();
              }
              final request = await client.getUrl(Uri.parse(address));
              route.headers.forEach(request.headers.set);
              request.headers.set('Range', 'bytes=0-4095');
              final received = await request.close();
              expect(received.statusCode, 206);
              expect(
                await received.fold<List<int>>([], (a, b) => a..addAll(b)),
                bytes,
              );
            }
            expect(media, 1);
            expect(fabricated, 0);
          } finally {
            await origin?.close();
            await disc?.close();
            client.close(force: true);
            api.close();
            await server.close(force: true);
          }
        }, LoopbackHttpOverrides());
      },
    );
  }
  for (final profile in ['', '0', 'invalid', '11', '5', '8']) {
    test(
      'opened media profile $profile selects output before returning',
      () async {
        final steps = <String>[];
        final actual = await prepareOpenedDolby(
          address: 'same-media',
          read: (key) async {
            steps.add(key);
            return key == 'path' ? 'same-media' : profile;
          },
          enable: () async {
            steps.add('enable');
          },
          active: () => true,
        );
        expect(
          actual,
          profile == '5' || profile == '8' ? int.parse(profile) : null,
        );
        expect(steps.contains('enable'), profile == '5' || profile == '8');
        if (actual != null) expect(steps.last, 'enable');
      },
    );
  }
  test('late profile and another media cannot enable stale output', () async {
    var active = true, writes = 0;
    final gate = Completer<String>();
    final pending = prepareOpenedDolby(
      address: 'same',
      read: (key) async => key == 'path' ? 'same' : gate.future,
      enable: () async {
        writes++;
      },
      active: () => active,
    );
    await Future<void>.delayed(Duration.zero);
    active = false;
    gate.complete('5');
    expect(await pending, isNull);
    expect(
      await prepareOpenedDolby(
        address: 'new',
        read: (_) async => 'old',
        enable: () async {
          writes++;
        },
        active: () => true,
      ),
      isNull,
    );
    expect(writes, 0);
  });
  test(
    'output failure is propagated instead of declaring mapping enabled',
    () async {
      await expectLater(
        prepareOpenedDolby(
          address: 'same',
          read: (key) async => key == 'path' ? 'same' : '5',
          enable: () async => throw StateError('synthetic output failure'),
          active: () => true,
        ),
        throwsStateError,
      );
    },
  );
  test('structured range aliases enable mapping but titles do not', () {
    for (final fields in [
      {'VideoRange': 'DolbyVision'},
      {'ExtendedVideoSubtype': 'DoviProfile81'},
      {'VideoRangeType': 'DOVIWithHDR10'},
    ]) {
      expect(
        requestsDolbyMapping([
          {'Type': 'Video', ...fields},
        ]),
        true,
      );
    }
    expect(
      requestsDolbyMapping([
        {'Type': 'Video', 'Title': 'DoVi', 'VideoRange': 'HDR10'},
      ]),
      false,
    );
  });
}
