import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/server_connection.dart';
import 'core_test.dart' show response, syntheticSession, playbackData;
import 'startup_test.dart' show sourceFor, detailFor;

class WaitingPlaybackClient extends http.BaseClient {
  final aborted = Completer<void>();
  var calls = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    await (request as http.AbortableRequest).abortTrigger;
    aborted.complete();
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final failure in ['timeout', 'network', '500', '403', '429', 'json']) {
    test(
      'regression079 media $failure preserves successful connection',
      () async {
        var calls = 0, expired = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            calls++;
            if (!request.url.path.endsWith('/PlaybackInfo')) {
              return response(
                jsonEncode(detailFor(sourceFor('mkv')).data),
                200,
              );
            }
            if (failure == 'timeout') throw TimeoutException('synthetic');
            if (failure == 'network') throw http.ClientException('synthetic');
            if (failure == 'json') return response('<html>invalid</html>', 200);
            return response('{}', int.parse(failure));
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        api.onUnauthorized = () => expired++;
        final account = api.session;
        final detail = await api.detail('movie');
        expect(api.connection.status, ServerStatus.connected);
        final checkedAt = api.connection.checkedAt;
        await expectLater(api.playback(detail), throwsA(isA<AppFailure>()));
        expect(api.connection.status, ServerStatus.connected);
        expect(api.connection.checkedAt, checkedAt);
        expect(identical(api.session, account), true);
        expect(expired, 0);
        expect(calls, 2, reason: 'No media probe or automatic retry');
      },
    );
  }

  test(
    'timed out media request is aborted and still reports playback failure',
    () async {
      final client = WaitingPlaybackClient();
      final api = EmbyClient(
        client: client,
        timeout: const Duration(milliseconds: 10),
      )..session = syntheticSession();
      addTearDown(api.close);
      api.connection.finish(api.connection.begin(), ServerStatus.connected);
      await expectLater(
        api.playback(detailFor(sourceFor('mkv'))),
        throwsA(
          isA<AppFailure>().having(
            (error) => error.message,
            'message',
            contains('播放信息请求超时'),
          ),
        ),
      );
      await client.aborted.future;
      expect(api.connection.status, ServerStatus.connected);
      expect(client.calls, 1);
    },
  );

  test(
    'media 401 still reports authentication failure and expires account',
    () async {
      var expired = 0;
      final api = EmbyClient(
        client: MockClient((_) async => response('{}', 401)),
      )..session = syntheticSession();
      addTearDown(api.close);
      api.onUnauthorized = () => expired++;
      api.connection.finish(api.connection.begin(), ServerStatus.connected);
      await expectLater(
        api.playback(detailFor(sourceFor('mkv'))),
        throwsA(
          isA<AppFailure>().having((error) => error.status, 'status', 401),
        ),
      );
      expect(api.connection.status, ServerStatus.denied);
      expect(expired, 1);
    },
  );

  test(
    'failed media does not erase a known outage; successful API recovers it',
    () async {
      var fail = true;
      final api = EmbyClient(
        client: MockClient((_) async {
          if (fail) throw TimeoutException('synthetic');
          return response(jsonEncode(playbackData()), 200);
        }),
      )..session = syntheticSession();
      addTearDown(api.close);
      api.connection.finish(
        api.connection.begin(),
        ServerStatus.disconnected,
        reason: 'known outage',
      );
      await expectLater(
        api.playback(detailFor(sourceFor('mkv'))),
        throwsA(isA<AppFailure>()),
      );
      expect(api.connection.status, ServerStatus.disconnected);
      expect(api.connection.detail, 'known outage');
      fail = false;
      await api.playback(detailFor(sourceFor('mkv')));
      expect(api.connection.status, ServerStatus.connected);
      expect(api.connection.recovery, 1);
      fail = true;
      await expectLater(api.testConnection(), throwsA(isA<AppFailure>()));
      expect(api.connection.status, ServerStatus.disconnected);
    },
  );

  for (final extension in ['mkv', 'iso']) {
    test(
      'regression079 fresh explicit $extension entry avoids redundant negotiation',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((_) async {
            calls++;
            throw TimeoutException('unneeded negotiation');
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        const address =
            'https://media.invalid/original?sig=a%2fb&part=1&part=2';
        final source = {
          ...sourceFor(extension),
          'Protocol': 'Http',
          'IsRemote': true,
          'Path': 'https://source.invalid/stale',
          'DirectStreamUrl': address,
          'DefaultAudioStreamIndex': 2,
          'DefaultSubtitleStreamIndex': -1,
          'RequiredHttpHeaders': {
            'Referer': 'https://required.invalid/',
            'X-Emby-Token': 'DO_NOT_FORWARD',
          },
          'MediaStreams': [
            {'Type': 'Video', 'Index': 0, 'Codec': 'hevc', 'DoviProfile': 8},
          ],
        };
        final route = await api.preparePlayback(
          detailFor(source),
          sourceId: 'source-1',
        );
        expect(calls, 0);
        expect(route.url, address);
        expect(route.defaultAudioIndex, 2);
        expect(route.defaultSubtitleIndex, -1);
        expect(route.sourceId, 'source-1');
        expect(route.streams.single['DoviProfile'], 8);
        expect(route.headers['Referer'], 'https://required.invalid/');
        expect(route.headers['X-Emby-Token'], isNull);
        expect(route.sameOriginHeaders, isEmpty);
        expect(
          route.discKind,
          extension == 'iso' ? DiscKind.iso : DiscKind.none,
        );
        expect(route.sessionId, isNotEmpty);
      },
    );
  }

  for (final direct in [
    '/emby/custom-route/movie',
    'https://synthetic.invalid/signed?sig=%2f',
    '/emby/Videos/movie/stream?Static=true&signature=opaque',
  ]) {
    test('fresh explicit original entry is preserved: $direct', () async {
      final api = EmbyClient(
        client: MockClient((_) async => throw StateError('Unneeded request')),
      )..session = syntheticSession();
      addTearDown(api.close);
      final route = await api.preparePlayback(
        detailFor({...sourceFor('mkv'), 'DirectStreamUrl': direct}),
      );
      expect(route.url, resolveMediaAddress(api.session!.base, direct));
    });
  }

  for (final change in <Json>[
    {'DirectStreamUrl': '/emby/Videos/movie/stream?Static=false'},
    {'DirectStreamUrl': '/emby/Videos/movie/stream?Static=true&static=false'},
    {'DirectStreamUrl': 'file:///private/file.mkv'},
    {'DirectStreamUrl': 'https://'},
    {
      'DirectStreamUrl':
          '/emby/Videos/movie/stream?Static=true&PlaySessionId=previous',
    },
    {
      'DirectStreamUrl':
          '/emby/Videos/movie/stream?Static=true&MediaSourceId=other',
    },
    {'RequiresOpening': true},
    {'RequiresClosing': true},
    {'IsInfiniteStream': true},
    {'LiveStreamId': 'live'},
    {'OpenToken': 'open'},
    {'Type': 'LiveStream'},
    {'SupportsDirectStream': false},
    {'RequiredHttpHeaders': null},
    {'MediaStreams': null},
    {
      'MediaStreams': [
        {'Type': 'Audio', 'Index': 0},
      ],
    },
  ]) {
    test(
      'unsafe or incomplete explicit source still negotiates: $change',
      () async {
        var calls = 0;
        final api = EmbyClient(
          client: MockClient((request) async {
            calls++;
            expect(request.url.path, endsWith('/PlaybackInfo'));
            expect(jsonDecode(request.body)['EnableTranscoding'], false);
            return response(jsonEncode(playbackData()), 200);
          }),
        )..session = syntheticSession();
        addTearDown(api.close);
        await api.preparePlayback(
          detailFor({
            ...sourceFor('mkv'),
            'Protocol': 'Http',
            'DirectStreamUrl': 'https://media.invalid/original.mkv',
            ...change,
          }),
        );
        expect(calls, 1);
      },
    );
  }
}
