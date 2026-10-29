import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'host/transport083/origin_transport_previous.dart' as previous_origin;
import 'host/transport083/disc_transport_previous.dart' as previous_disc;

typedef _Reply = ({int status, String? location});

class _WireServer {
  _WireServer(this.server, this.reply) {
    subscription = server.listen((socket) {
      sockets.add(socket);
      var request = '', answered = false;
      socket.listen((data) async {
        request += latin1.decode(data);
        if (answered || !request.contains('\r\n\r\n')) return;
        answered = true;
        requests.add(request);
        final target = request.split('\r\n').first.split(' ')[1];
        final answer = reply(target, requests.length);
        final success = answer.status == 206;
        socket.add(
          ascii.encode(
            'HTTP/1.1 ${answer.status} Fixture\r\n'
            'Content-Length: ${success ? 4 : 0}\r\n'
            '${success ? 'Content-Range: bytes 0-3/4\r\n' : ''}'
            '${answer.location == null ? '' : 'Location: ${answer.location}\r\n'}'
            'Connection: close\r\n\r\n',
          ),
        );
        if (success) socket.add([1, 2, 3, 4]);
        await socket.close();
      }, onError: (Object _) {});
    });
  }

  static Future<_WireServer> bind(_Reply Function(String, int) reply) async =>
      _WireServer(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        reply,
      );

  final ServerSocket server;
  final _Reply Function(String, int) reply;
  late final StreamSubscription<Socket> subscription;
  final sockets = <Socket>[];
  final requests = <String>[];
  String get base => 'http://127.0.0.1:${server.port}';
  List<String> get targets => requests
      .map((request) => request.split('\r\n').first.split(' ')[1])
      .toList();
  Future<void> close() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    await subscription.cancel();
    await server.close();
  }
}

PlaybackRoute _route(String base, String url) => PlaybackRoute(
  url: url,
  sourceId: 'SYNTHETIC_SOURCE',
  sessionId: 'SYNTHETIC_SESSION',
  streams: [],
  headers: const {'User-Agent': 'Yingyu-signed-fixture'},
  sameOriginHeaders: const {
    'X-Emby-Token': 'SYNTHETIC_TOKEN',
    'X-Emby-Authorization': 'Emby UserId="SYNTHETIC_USER"',
  },
  diagnosticSecrets: const ['SYNTHETIC_TOKEN', 'SYNTHETIC_USER'],
  serverBase: Uri.parse(base),
);

const _entry = '/emby/Videos/stream?api_key=SYNTHETIC_TOKEN&Static=true';
const _signed = '/emby/resolve/%41%2f%7e?sign=a%2fb%2Bc&literal=%41&x=1&x=2';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Complete old and current production transports use identical raw sockets.
  // The fixture checks request bytes, rather than a Uri's decoded query values.
  for (final disc in [false, true]) {
    for (final variant in ['entry', 'absolute', 'root', 'relative', 'query']) {
      for (final previous in [true, false]) {
        test(
          '${previous ? 'old' : 'current'} ${disc ? 'disc' : 'origin'} preserves signed $variant request bytes',
          () => HttpOverrides.runWithHttpOverrides(() async {
            final isEntry = variant == 'entry';
            final expected = variant == 'query'
                ? '/emby/Videos/stream?sign=a%2fb%2Bc&literal=%41&x=1&x=2'
                : _signed;
            late final _WireServer wire;
            wire = await _WireServer.bind((target, count) {
              if (!isEntry && count == 1) {
                final location = switch (variant) {
                  'absolute' => '${wire.base}$_signed',
                  'root' => _signed,
                  'relative' =>
                    '../resolve/%41%2f%7e?sign=a%2fb%2Bc&literal=%41&x=1&x=2',
                  _ => '?sign=a%2fb%2Bc&literal=%41&x=1&x=2',
                };
                return (status: 302, location: location);
              }
              return (status: target == expected ? 206 : 403, location: null);
            });
            final log = DiagnosticLog();
            final selected = _route(
              wire.base,
              '${wire.base}${isEntry ? expected : _entry}',
            );
            final dynamic transport = disc
                ? previous
                      ? previous_disc.DiscTransport(
                          selected,
                          kind: DiscKind.iso,
                          directInput: true,
                          log: log,
                          nativeInvoke: (_, _) async => null,
                        )
                      : DiscTransport(
                          selected,
                          kind: DiscKind.iso,
                          directInput: true,
                          log: log,
                          nativeInvoke: (_, _) async => null,
                        )
                : previous
                ? previous_origin.EmbyOriginTransport(selected, log: log)
                : EmbyOriginTransport(selected, log: log);
            final native = HttpClient();
            // Old disc transport already preserves absolute targets, but its
            // relative Location resolution normalizes the signed bytes.
            final succeeds =
                !previous || (disc && (isEntry || variant == 'absolute'));
            try {
              if (disc) {
                Future<DiscRangeBlock?> read() async =>
                    await transport.readNativeInput(
                          1,
                          '',
                          0,
                          4,
                          DiscReadCancellation(),
                        )
                        as DiscRangeBlock?;
                if (succeeds) {
                  expect((await read())!.bytes, [1, 2, 3, 4]);
                } else {
                  await expectLater(read(), throwsA(isA<AppFailure>()));
                }
              } else {
                final request = await native.getUrl(
                  Uri.parse(await transport.start() as String),
                );
                request.headers.set('Range', 'bytes=0-3');
                final response = await request.close();
                expect(response.statusCode, succeeds ? 206 : 403);
                final bytes = await response.fold<List<int>>(
                  [],
                  (all, chunk) => all..addAll(chunk),
                );
                expect(bytes, succeeds ? [1, 2, 3, 4] : isNot([1, 2, 3, 4]));
              }
              expect(
                wire.requests.length,
                isEntry ? 1 : 2,
                reason: 'no probe or retry of the signed entry',
              );
              expect(wire.targets.last == expected, succeeds);
              for (final request in wire.requests) {
                expect(
                  request.toLowerCase(),
                  contains('x-emby-token: synthetic_token'),
                );
                expect(request.toLowerCase(), contains('range: bytes=0-3'));
              }
              if (disc && !previous) {
                expect(log.export(), contains('原盘请求已就绪'));
                expect(log.export(), contains('等待响应头上限=30 秒'));
              }
              expect(log.export(), isNot(contains('SYNTHETIC_TOKEN')));
            } finally {
              native.close(force: true);
              await transport.close();
              log.dispose();
              await wire.close();
            }
          }, LoopbackHttpOverrides()),
        );
      }
    }
  }

  for (final disc in [false, true]) {
    for (final initial in [true, false]) {
      for (final input in const [
        (
          name: 'Unicode and spaces',
          entry: '/emby/中 文/%41?name=片 名&sign=%2f',
          location:
              '../%E4%B8%AD %E6%96%87/%41?name=%E7%89%87 %E5%90%8D&sign=%2f',
          expected:
              '/emby/%E4%B8%AD%20%E6%96%87/%41?name=%E7%89%87%20%E5%90%8D&sign=%2f',
        ),
        (
          name: 'illegal ASCII',
          entry:
              r'''/emby/[Group]/a"<>^`{|}.mkv?name=[Cut]"<>^`{|}&keep=!$&'()*+,-./:;=?@_~&sign=%2f%41&x=1&x=2''',
          location:
              r'''../[Group]/a"<>^`{|}.mkv?name=[Cut]"<>^`{|}&keep=!$&'()*+,-./:;=?@_~&sign=%2f%41&x=1&x=2''',
          expected:
              r'''/emby/%5BGroup%5D/a%22%3C%3E%5E%60%7B%7C%7D.mkv?name=%5BCut%5D%22%3C%3E%5E%60%7B%7C%7D&keep=!$&'()*+,-./:;=?@_~&sign=%2f%41&x=1&x=2''',
        ),
        (
          name: 'bare invalid percent',
          entry: '/emby/100%/bad%2G/%?q=%&half=%2&bad=%g0&valid=%2f%41&x=1&x=2',
          location: '../100%/bad%2G/%?q=%&half=%2&bad=%g0&valid=%2f%41&x=1&x=2',
          expected:
              '/emby/100%25/bad%252G/%25?q=%25&half=%252&bad=%25g0&valid=%2f%41&x=1&x=2',
        ),
        (
          name: 'path and query backslash',
          entry: r'/emby/folder\part.mkv?q=one\two&sign=%2f',
          location: r'../folder\part.mkv?q=one\two&sign=%2f',
          expected: '/emby/folder/part.mkv?q=one%5Ctwo&sign=%2f',
        ),
        (
          name: 'legal component separators',
          entry:
              r'''/emby/a!$&'()*+,-.:;=@_~/%2f%41?keep=!$&'()*+,-./:;=?@_~&x=1&x=2''',
          location:
              r'''../a!$&'()*+,-.:;=@_~/%2f%41?keep=!$&'()*+,-./:;=?@_~&x=1&x=2''',
          expected:
              r'''/emby/a!$&'()*+,-.:;=@_~/%2f%41?keep=!$&'()*+,-./:;=?@_~&x=1&x=2''',
        ),
      ]) {
        test(
          'current ${disc ? 'disc' : 'origin'} encodes ${input.name} while preserving signed ${initial ? 'entry' : 'relative'} bytes',
          () => HttpOverrides.runWithHttpOverrides(() async {
            final expected = input.expected;
            final wire = await _WireServer.bind((target, count) {
              if (!initial && count == 1) {
                return (status: 302, location: input.location);
              }
              return (status: target == expected ? 206 : 403, location: null);
            });
            final selected = _route(
              wire.base,
              '${wire.base}${initial ? input.entry : _entry}',
            );
            final dynamic transport = disc
                ? DiscTransport(
                    selected,
                    kind: DiscKind.iso,
                    directInput: true,
                    nativeInvoke: (_, _) async => null,
                  )
                : EmbyOriginTransport(selected);
            final native = HttpClient();
            try {
              if (disc) {
                final block =
                    await transport.readNativeInput(
                          1,
                          '',
                          0,
                          4,
                          DiscReadCancellation(),
                        )
                        as DiscRangeBlock?;
                expect(block!.bytes, [1, 2, 3, 4]);
              } else {
                final request = await native.getUrl(
                  Uri.parse(await transport.start() as String),
                );
                request.headers.set('Range', 'bytes=0-3');
                final response = await request.close();
                expect(response.statusCode, 206);
                expect(
                  await response.fold<List<int>>(
                    [],
                    (all, chunk) => all..addAll(chunk),
                  ),
                  [1, 2, 3, 4],
                );
              }
              expect(wire.targets.last, expected);
              expect(wire.requests.length, initial ? 1 : 2);
            } finally {
              native.close(force: true);
              await transport.close();
              await wire.close();
            }
          }, LoopbackHttpOverrides()),
        );
      }
    }

    test(
      'current ${disc ? 'disc' : 'origin'} preserves external signature and isolates account headers',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final external = await _WireServer.bind(
          (_, _) => (status: 206, location: null),
        );
        final signed = '${external.base}/media/%41%2f?sign=a%2fb%2Bc&x=1&x=2';
        final origin = await _WireServer.bind(
          (_, _) => (status: 302, location: signed),
        );
        final selected = _route(origin.base, '${origin.base}$_entry');
        final dynamic transport = disc
            ? DiscTransport(
                selected,
                kind: DiscKind.iso,
                directInput: true,
                nativeInvoke: (_, _) async => null,
              )
            : EmbyOriginTransport(selected);
        final native = HttpClient();
        try {
          if (disc) {
            final block =
                await transport.readNativeInput(
                      1,
                      '',
                      0,
                      4,
                      DiscReadCancellation(),
                    )
                    as DiscRangeBlock?;
            expect(block!.bytes, [1, 2, 3, 4]);
            expect(external.targets, ['/media/%41%2f?sign=a%2fb%2Bc&x=1&x=2']);
            expect(
              external.requests.single.toLowerCase(),
              isNot(contains('x-emby')),
            );
          } else {
            final address = Uri.parse(await transport.start() as String);
            for (var i = 0; i < 3; i++) {
              final request = await native.openUrl(
                i == 0 ? 'GET' : 'HEAD',
                address,
              );
              request.followRedirects = false;
              final response = await request.close();
              expect(response.statusCode, 302);
              expect(response.headers.value('location'), signed);
              await response.drain<void>();
            }
            expect(
              external.requests,
              isEmpty,
              reason: 'MPV receives Location without a preflight GET',
            );
          }
          expect(origin.requests.length, 1);
        } finally {
          native.close(force: true);
          await transport.close();
          await origin.close();
          await external.close();
        }
      }, LoopbackHttpOverrides()),
    );

    for (final loop in [true, false]) {
      test(
        'current ${disc ? 'disc' : 'origin'} keeps ${loop ? 'loop' : 'eight-hop'} failure bounded',
        () => HttpOverrides.runWithHttpOverrides(() async {
          final origin = await _WireServer.bind(
            (_, count) =>
                (status: 302, location: loop ? _entry : '/hop/$count?sign=%41'),
          );
          final selected = _route(origin.base, '${origin.base}$_entry');
          final dynamic transport = disc
              ? DiscTransport(
                  selected,
                  kind: DiscKind.iso,
                  directInput: true,
                  nativeInvoke: (_, _) async => null,
                )
              : EmbyOriginTransport(selected);
          final native = HttpClient();
          try {
            if (disc) {
              await expectLater(
                transport.readNativeInput(1, '', 0, 4, DiscReadCancellation()),
                throwsA(isA<AppFailure>()),
              );
            } else {
              final request = await native.getUrl(
                Uri.parse(await transport.start() as String),
              );
              final response = await request.close();
              expect(response.statusCode, 502);
              await response.drain<void>();
            }
            expect(origin.requests.length, loop ? 1 : 8);
          } finally {
            native.close(force: true);
            await transport.close();
            await origin.close();
          }
        }, LoopbackHttpOverrides()),
      );
    }
  }

  test(
    'relative HTTP references retain escapes and RFC dot-segment behavior',
    () {
      final base = ExactHttpUri('https://example.invalid/a/b/c?old=%41');
      for (final entry in <String, String>{
        '': 'https://example.invalid/a/b/c?old=%41',
        '#ignored': 'https://example.invalid/a/b/c?old=%41',
        '?new=%2f&x=1&x=2': 'https://example.invalid/a/b/c?new=%2f&x=1&x=2',
        '../%41/%2e%2e?sig=%7e': 'https://example.invalid/a/%41/%2e%2e?sig=%7e',
        '../../..//%41?': 'https://example.invalid//%41?',
        '/a/./b/../%7e': 'https://example.invalid/a/%7e',
        './': 'https://example.invalid/a/b/',
        '../': 'https://example.invalid/a/',
        '//cdn.invalid/%41?sign=%2f': 'https://cdn.invalid/%41?sign=%2f',
        '../中 文/%41?name=片 名&sign=%2f':
            'https://example.invalid/a/%E4%B8%AD%20%E6%96%87/%41?name=%E7%89%87%20%E5%90%8D&sign=%2f',
        r'..\folder\part?x=one\two':
            'https://example.invalid/a/folder/part?x=one%5Ctwo',
        r'..\%5c\%2e%2e?x=%5c': 'https://example.invalid/a/%5c/%2e%2e?x=%5c',
      }.entries) {
        expect(
          base.resolve(entry.key).toString(),
          entry.value,
          reason: entry.key,
        );
      }
    },
  );

  test('unsigned literal component escaping matches the fixed Dart SDK', () {
    for (final address in const [
      r'''https://example.invalid/[Group]/a"<>^`{|}.mkv?q=[Cut]"<>^`{|}''',
      'https://example.invalid/100%/bad%2G/%?q=%&half=%2&bad=%g0',
      r'https://example.invalid/folder\part.mkv?q=one\two',
      'https://example.invalid/中 文/片名?q=中文 名称',
    ]) {
      expect(
        ExactHttpUri(address).toString(),
        Uri.parse(address).toString(),
        reason: address,
      );
    }
  });

  test(
    'literal request controls remain rejected rather than being escaped',
    () {
      final base = ExactHttpUri('https://example.invalid/a/b?sign=%2f');
      for (final control in ['\u0000', '\u001f', '\r', '\n', '\u007f']) {
        expect(
          () => ExactHttpUri('https://example.invalid/a${control}b'),
          throwsA(isA<AppFailure>()),
        );
        expect(
          () => ExactHttpUri('https://example.invalid/a?q=$control'),
          throwsA(isA<AppFailure>()),
        );
        expect(
          () => base.resolve('../a${control}b?sign=%2f'),
          throwsA(isA<AppFailure>()),
        );
      }
    },
  );
}
