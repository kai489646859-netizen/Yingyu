import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'core_test.dart'
    show LoopbackHttpOverrides, syntheticSession, response, playbackData;
import 'startup_test.dart' show sourceFor, detailFor;
import 'static_original080_test.dart' show completeLocalStaticSource;

void main() {
  for (final container in ['mkv', 'mp4', 'm2ts', 'webm']) {
    test(
      'known $container reaches a standard302 entry before a legacy fallback',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final releaseLegacy = Completer<void>();
          final base = 'http://127.0.0.1:${server.port}/proxy/emby';
          final paths = <String>[];
          final queries = <Map<String, String>>[];
          var closing = false;
          final api = EmbyClient(
            client: MockClient(
              (_) async => throw StateError('no extra metadata'),
            ),
          )..session = syntheticSession(base);
          final source = completeLocalStaticSource({'Container': container});
          final route = await api.preparePlayback(detailFor(source));
          final origin = EmbyOriginTransport(route);
          final client = HttpClient();
          server.listen((req) async {
            try {
              paths.add(req.uri.path);
              queries.add(req.uri.queryParameters);
              expect(req.headers.value('x-emby-token'), api.session!.token);
              expect(req.headers.value('range'), 'bytes=0-1023');
              if (!req.uri.path.endsWith('/stream.$container')) {
                await releaseLegacy.future;
              }
              req.response.statusCode = 302;
              req.response.contentLength = 0;
              req.response.headers.set(
                'Location',
                'https://synthetic.invalid/asset?sig=a%2fb&x=1&x=2',
              );
              await req.response.close();
            } catch (_) {
              if (!closing) rethrow;
            }
          });
          try {
            final address = await origin.start();
            for (var i = 0; i < 2; i++) {
              final req = await client.getUrl(Uri.parse(address));
              req.followRedirects = false;
              req.headers.set('Range', 'bytes=0-1023');
              final reply = await req.close().timeout(
                const Duration(milliseconds: 500),
              );
              expect(reply.statusCode, 302);
              expect(
                reply.headers.value('location'),
                'https://synthetic.invalid/asset?sig=a%2fb&x=1&x=2',
              );
              await reply.listen((_) {}).cancel();
            }
            expect(paths, ['/proxy/emby/Videos/movie/stream.$container']);
            expect(queries.single, containsPair('Static', 'true'));
            expect(queries.single, containsPair('MediaSourceId', 'source-1'));
            expect(
              queries.single,
              containsPair('PlaySessionId', route.sessionId),
            );
            expect(
              queries.single,
              containsPair('DeviceId', api.session!.deviceId),
            );
          } finally {
            closing = true;
            if (!releaseLegacy.isCompleted) releaseLegacy.complete();
            client.close(force: true);
            await origin.close();
            api.close();
            await server.close(force: true);
          }
        }, LoopbackHttpOverrides());
      },
    );
  }

  test('unknown or STRM container never guesses a media suffix', () async {
    final api = EmbyClient(
      client: MockClient((_) async => throw StateError('no extra metadata')),
    )..session = syntheticSession();
    addTearDown(api.close);
    for (final container in ['', 'strm', 'mkv/mp4', '../mkv']) {
      final route = await api.preparePlayback(
        detailFor(completeLocalStaticSource({'Container': container})),
      );
      expect(Uri.parse(route.url).path, '/proxy/emby/Videos/movie/stream');
    }
  });

  for (final container in ['mkv', 'mp4']) {
    test(
      'non-proxied $container serves the exact requested bytes normally',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final api =
              EmbyClient(
                  client: MockClient(
                    (_) async => throw StateError('no metadata retry'),
                  ),
                )
                ..session = syntheticSession(
                  'http://127.0.0.1:${server.port}/proxy/emby',
                );
          final route = await api.preparePlayback(
            detailFor(completeLocalStaticSource({'Container': container})),
          );
          final data = List<int>.generate(256, (i) => i);
          final paths = <String>[];
          server.listen((req) async {
            paths.add(req.uri.path);
            expect(req.headers.value('x-emby-token'), api.session!.token);
            final range = RegExp(
              r'^bytes=(\d+)-(\d+)$',
            ).firstMatch(req.headers.value('range')!);
            final begin = int.parse(range![1]!), end = int.parse(range[2]!);
            req.response.statusCode = 206;
            req.response.contentLength = end - begin + 1;
            req.response.headers.set(
              'Content-Range',
              'bytes $begin-$end/${data.length}',
            );
            req.response.add(data.sublist(begin, end + 1));
            await req.response.close();
          });
          final origin = EmbyOriginTransport(route), client = HttpClient();
          try {
            final address = await origin.start();
            for (final begin in [0, 64]) {
              final req = await client.getUrl(Uri.parse(address));
              req.followRedirects = false;
              req.headers.set('Range', 'bytes=$begin-${begin + 63}');
              final reply = await req.close();
              expect(reply.statusCode, 206);
              expect(
                await reply.fold<List<int>>(
                  [],
                  (all, chunk) => all..addAll(chunk),
                ),
                data.sublist(begin, begin + 64),
              );
            }
            expect(
              paths,
              List.filled(2, '/proxy/emby/Videos/movie/stream.$container'),
            );
          } finally {
            client.close(force: true);
            await origin.close();
            api.close();
            await server.close(force: true);
          }
        }, LoopbackHttpOverrides());
      },
    );
  }

  test(
    'File protocol never discards a server-signed same-origin entry',
    () async {
      const signed =
          '/proxy/emby/Videos/movie/stream.mkv?Static=true&signature=a%2fb&x=1&x=2';
      final api = EmbyClient(
        client: MockClient((_) async => throw StateError('no extra metadata')),
      )..session = syntheticSession();
      addTearDown(api.close);
      final route = await api.preparePlayback(
        detailFor(sourceFor('mkv')..['DirectStreamUrl'] = signed),
      );
      expect(route.url, 'http://127.0.0.1:9$signed');
    },
  );

  for (final query in ['PlaySessionId=server-old', 'MediaSourceId=wrong']) {
    test(
      'File protocol negotiates a supplied $query instead of bypassing identity',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((_) async {
            calls++;
            return response(
              jsonEncode(
                playbackData(url: 'https://synthetic.invalid/negotiated.mkv'),
              ),
              200,
            );
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        final route = await api.preparePlayback(
          detailFor(
            sourceFor('mkv')
              ..['DirectStreamUrl'] =
                  '/proxy/emby/Videos/movie/stream.mkv?Static=true&$query',
          ),
        );
        expect(calls, 1);
        expect(route.url, 'https://synthetic.invalid/negotiated.mkv');
      },
    );
  }
}
