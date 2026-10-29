import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:yingyu/core/emby.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides, syntheticSession, response;
import 'startup_test.dart' show sourceFor, detailFor;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final scenario in [
    'success',
    '503',
    'invalid-range',
    'cancel',
    'close',
  ]) {
    test(
      'canonical ISO starts without waiting for detail Path: $scenario',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final base = 'http://127.0.0.1:${origin.port}';
          final external = 'http://127.0.0.1:${media.port}';
          var entries = 0, candidates = 0, resolved = 0;
          final arrived = Completer<void>(), release = Completer<void>();
          origin.listen((r) async {
            entries++;
            expect(r.headers.value('x-emby-token'), 'ACCOUNT');
            expect(r.uri.queryParameters['Static'], 'true');
            r.response.statusCode = 302;
            r.response.headers.set(
              'location',
              '$external/resolved?sig=%2f&k=1&k=2',
            );
            await r.response.close();
          });
          media.listen((r) async {
            try {
              expect(r.headers.value('x-emby-token'), isNull);
              expect(r.headers.value('x-emby-authorization'), isNull);
              if (r.uri.path == '/candidate.iso') {
                candidates++;
                await release.future;
                r.response.statusCode = 503;
              } else {
                resolved++;
                expect(r.headers.value('referer'), 'https://required.invalid/');
                expect(r.uri.queryParametersAll['k'], ['1', '2']);
                expect(r.uri.queryParameters['sig'], '/');
                if (!arrived.isCompleted) arrived.complete();
                if (scenario == 'cancel' || scenario == 'close') {
                  await release.future;
                }
                if (scenario == '503') {
                  r.response.statusCode = 503;
                } else {
                  final range = RegExp(
                    r'bytes=(\d+)-(\d+)',
                  ).firstMatch(r.headers.value('range')!)!;
                  final start = int.parse(range[1]!),
                      end = int.parse(range[2]!);
                  r.response.statusCode = 206;
                  r.response.headers.set(
                    'content-range',
                    'bytes ${scenario == 'invalid-range' ? start + 1 : start}-$end/65536',
                  );
                  r.response.contentLength = end - start + 1;
                  r.response.add(
                    List.generate(end - start + 1, (i) => (start + i) % 251),
                  );
                }
              }
              await r.response.close();
            } on HttpException {
              // The synthetic pending request was cancelled.
            } on SocketException {
              // The synthetic client has closed.
            }
          });
          final api = EmbyClient(
            client: MockClient(
              (_) async => response(
                jsonEncode({
                  'PlaySessionId': 'fresh-session',
                  'MediaSources': [
                    {
                      ...sourceFor('iso'),
                      'DirectStreamUrl':
                          '$base/Videos/movie/stream?Static=true',
                      'RequiredHttpHeaders': {
                        'Referer': 'https://required.invalid/',
                      },
                    },
                  ],
                }),
                200,
              ),
            ),
          )..session = syntheticSession();
          final session = api.session!;
          api.session = Session(
            base: Uri.parse(base),
            token: 'ACCOUNT',
            userId: session.userId,
            username: session.username,
            deviceId: session.deviceId,
          );
          final route = await api.preparePlayback(
            detailFor({
              ...sourceFor('iso'),
              'Protocol': 'Http',
              'SupportsDirectPlay': true,
              'Path': '$external/candidate.iso',
              'RequiredHttpHeaders': {'Referer': 'https://required.invalid/'},
            }),
          );
          final failures = <String>[];
          final transport = DiscTransport(
            route,
            kind: DiscKind.iso,
            directInput: true,
            nativeInvoke: (_, _) async => null,
            onFailure: failures.add,
          );
          final cancellation = DiscReadCancellation();
          try {
            final first = transport.readNativeInput(
              1,
              '',
              0,
              4096,
              cancellation,
            );
            final result = first.then<Object?>(
              (v) => v,
              onError: (Object e) => e,
            );
            await arrived.future.timeout(const Duration(seconds: 1));
            expect(candidates, 0);
            if (scenario == 'cancel') cancellation.cancel();
            if (scenario == 'close') await transport.close();
            if (!release.isCompleted) release.complete();
            final value = await result;
            if (scenario == 'success') {
              expect(
                (value as DiscRangeBlock).bytes,
                List.generate(4096, (i) => i % 251),
              );
              final next = await transport.readNativeInput(
                1,
                '',
                4096,
                4096,
                DiscReadCancellation(),
              );
              expect(next!.bytes, List.generate(4096, (i) => (4096 + i) % 251));
              expect(resolved, 2);
              expect(failures, isEmpty);
            } else {
              expect(value, isA<Exception>());
              if (scenario == '503' || scenario == 'invalid-range') {
                expect(failures, hasLength(1));
                expect(
                  failures.single,
                  contains(scenario == '503' ? 'HTTP 503' : '范围'),
                );
                expect(failures.single, isNot(contains('ACCOUNT')));
              } else {
                expect(failures, isEmpty);
              }
            }
            expect(entries, 1);
            expect(candidates, 0);
            expect(route.playMethod, 'DirectStream');
          } finally {
            if (!release.isCompleted) release.complete();
            await transport.close();
            api.close();
            await origin.close(force: true);
            await media.close(force: true);
          }
        }, LoopbackHttpOverrides());
      },
    );
  }
}
