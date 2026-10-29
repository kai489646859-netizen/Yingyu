import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'package:yingyu/playback/disc_transport.dart' show ExactHttpUri;
import 'core_test.dart' show syntheticSession, response, LoopbackHttpOverrides;
import 'startup_test.dart' show sourceFor, detailFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a current explicit remote URL is reused without negotiation or rewriting',
    () async {
      var calls = 0;
      const exact = 'https://media.invalid/ready.mp4?sig=a%2fb&x=1&x=2';
      final api = EmbyClient(
        client: MockClient((_) async {
          calls++;
          throw StateError('unexpected request');
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      final route = await api.preparePlayback(
        detailFor({
          ...sourceFor('mp4'),
          'Protocol': 'Http',
          'IsRemote': true,
          'Path': 'https://server-only.invalid/stale.mp4',
          'DirectStreamUrl': exact,
        }),
      );
      expect(route.url, exact);
      expect(calls, 0);
      expect(route.sameOriginHeaders, isEmpty);
    },
  );
  test(
    'failed incomplete remote negotiation never opens the unverified detail Path or retries',
    () async {
      var calls = 0;
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          expect(r.url.path, endsWith('/PlaybackInfo'));
          return response('server unavailable', 503);
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      await expectLater(
        api.preparePlayback(
          detailFor({
            ...sourceFor('mp4'),
            'Protocol': 'Http',
            'IsRemote': true,
            // Missing headers require server negotiation.
            'RequiredHttpHeaders': null,
            'Path': 'https://server-only.invalid/stale.mp4',
          }),
        ),
        throwsException,
      );
      expect(calls, 1);
    },
  );
  test(
    'server negotiation keeps the selected source and returns its own playback session',
    () async {
      var calls = 0;
      final first = {
        ...sourceFor('mp4'),
        'Protocol': 'Http',
        'IsRemote': true,
        // Missing headers require server negotiation.
        'RequiredHttpHeaders': null,
        'Id': 'first',
        'Path': 'https://server-only.invalid/first.mp4',
      };
      final selected = {
        ...first,
        'Id': 'chosen',
        'Path': 'https://server-only.invalid/chosen.mp4',
      };
      final api = EmbyClient(
        client: MockClient((r) async {
          calls++;
          expect(jsonDecode(r.body)['MediaSourceId'], 'chosen');
          return response(
            jsonEncode({
              'PlaySessionId': 'current-server-session',
              'MediaSources': [
                {
                  ...first,
                  'DirectStreamUrl': 'https://media.invalid/first.mp4',
                },
                {
                  ...selected,
                  'DirectStreamUrl': 'https://media.invalid/chosen.mp4',
                },
              ],
            }),
            200,
          );
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      final detail = detailFor(first);
      detail.data['MediaSources'] = [first, selected];
      final route = await api.preparePlayback(detail, sourceId: 'chosen');
      expect(route.sourceId, 'chosen');
      expect(route.sessionId, 'current-server-session');
      expect(route.url, 'https://media.invalid/chosen.mp4');
      expect(calls, 1);
    },
  );
  test(
    'incomplete remote detail cannot force a stalled fabricated entry over a ready negotiated stream',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final entry = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final gate = Completer<void>();
        var legacy = 0, negotiation = 0, streamed = 0;
        final base = 'http://127.0.0.1:${entry.port}';
        final ready =
            'http://127.0.0.1:${media.port}/ready.mp4?sig=a%2fb&x=1&x=2';
        entry.listen((r) async {
          legacy++;
          await gate.future;
          try {
            await r.response.close();
          } catch (_) {}
        });
        media.listen((r) async {
          streamed++;
          // HttpServer parses/normalizes its Uri. The opaque route string is
          // checked separately before transport, as in the existing range tests.
          expect(r.uri.query, Uri.parse(ready).query);
          expect(r.headers.value('x-emby-token'), isNull);
          expect(r.headers.value('x-emby-authorization'), isNull);
          expect(r.headers.value('range'), 'bytes=0-3');
          expect(r.headers.value('referer'), 'https://required.invalid/');
          r.response.statusCode = 206;
          r.response.contentLength = 4;
          r.response.headers.set('content-range', 'bytes 0-3/4');
          r.response.add([1, 2, 3, 4]);
          await r.response.close();
        });
        final source = {
          ...sourceFor('mp4'),
          'Protocol': 'Http',
          'IsRemote': true,
          // Missing headers require server negotiation.
          'RequiredHttpHeaders': null,
          'Path': 'https://server-only.invalid/not-a-client-entry.mp4',
          'SupportsDirectPlay': true,
        };
        final api = EmbyClient(
          client: MockClient((r) async {
            negotiation++;
            expect(r.url.path, '/Items/movie/PlaybackInfo');
            final body = jsonDecode(r.body) as Map;
            expect(body['EnableTranscoding'], false);
            expect(body['StartTimeTicks'], 2860000000);
            return response(
              jsonEncode({
                'PlaySessionId': 'server-session',
                'MediaSources': [
                  {
                    ...source,
                    'DirectStreamUrl': ready,
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
        final http = HttpClient();
        EmbyOriginTransport? origin;
        try {
          final route = await api.preparePlayback(
            detailFor(source),
            start: const Duration(seconds: 286),
          );
          expect(route.url, ready);
          var address = route.url;
          if (route.sameOriginHeaders.isNotEmpty) {
            origin = EmbyOriginTransport(route);
            address = await origin.start();
          }
          final req = await http.getUrl(ExactHttpUri(address));
          route.headers.forEach(req.headers.set);
          req.headers.set('Range', 'bytes=0-3');
          final reply = await req.close().timeout(
            const Duration(milliseconds: 750),
            onTimeout: () => throw StateError(
              'stalled fabricated entry selected although the negotiated stream was ready',
            ),
          );
          expect(await reply.fold<List<int>>([], (a, b) => a..addAll(b)), [
            1,
            2,
            3,
            4,
          ]);
          expect(negotiation, 1);
          expect(legacy, 0);
          expect(streamed, 1);
          expect(route.sessionId, 'server-session');
        } finally {
          if (!gate.isCompleted) gate.complete();
          http.close(force: true);
          await origin?.close();
          api.close();
          await entry.close(force: true);
          await media.close(force: true);
        }
      }, LoopbackHttpOverrides());
    },
  );
}
