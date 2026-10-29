import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yingyu/core/store.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'core_test.dart' show LoopbackHttpOverrides, syntheticSession;

final titleData = jsonEncode([
  {
    'playlist': 1,
    'duration': 180000,
    'clips': [
      {'id': '00001', 'in': 54000000, 'out': 54090000},
      {'id': '00002', 'in': 90000, 'out': 180000},
    ],
    'chapters': [0, 90000],
  },
]);
PlaybackRoute route(String url, {Uri? origin, DiscKind kind = DiscKind.iso}) =>
    PlaybackRoute(
      url: url,
      sourceId: 'synthetic-disc',
      sessionId: 'synthetic-play',
      headers: {'User-Agent': 'Synthetic/1'},
      streams: [],
      discKind: kind,
      serverBase: origin,
      sameOriginHeaders: origin == null
          ? {}
          : {
              'X-Emby-Token': 'SYNTHETIC_TOKEN',
              'X-Emby-Authorization': 'MediaBrowser UserId="SYNTHETIC_USER"',
            },
    );

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(
    () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
      DiscTransport.channel,
      null,
    ),
  );

  for (final kind in [DiscKind.iso, DiscKind.blurayFolder]) {
    test(
      'sequential ${kind.name} HTTP playback coalesces authenticated ranges without changing signed targets',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          const mib = 1024 * 1024, baseOffset = 5 * 1024 * mib;
          const total = baseOffset + 32 * mib;
          final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final external = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final originBase = Uri.parse('http://127.0.0.1:${origin.port}');
          final externalBase = 'http://127.0.0.1:${external.port}';
          var calls = 0;
          origin.listen((req) async {
            expect(req.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
            req.response.statusCode = 302;
            req.response.headers.set(
              'Location',
              '$externalBase${req.uri.path}?sig=%2f%2B&x=a+b&x=2',
            );
            await req.response.close();
          });
          external.listen((req) async {
            expect(req.headers.value('x-emby-token'), null);
            expect(req.headers.value('x-emby-authorization'), null);
            // HttpServer parses Uri and normalizes percent-escape casing. Exact
            // wire spelling is covered separately by the raw ServerSocket test.
            expect(req.uri.queryParametersAll, {
              'sig': ['/+'],
              'x': ['a b', '2'],
            });
            final range = discByteRange(req.headers.value('range'), total)!;
            if (range.start >= baseOffset) calls++;
            final data = Uint8List(range.end - range.start + 1);
            for (var i = 0; i < data.length; i++) {
              data[i] = (range.start + i) % 251;
            }
            req.response.statusCode = 206;
            req.response.headers.set(
              'Content-Range',
              'bytes ${range.start}-${range.end}/$total',
            );
            req.response.contentLength = data.length;
            req.response.add(data);
            await req.response.close();
          });
          binding.defaultBinaryMessenger.setMockMethodCallHandler(
            DiscTransport.channel,
            (call) async => call.method == 'open' ? titleData : null,
          );
          final log = DiagnosticLog();
          final url =
              '$originBase/${kind == DiscKind.iso ? "film.iso" : "disc/BDMV/index.bdmv"}';
          final transport = DiscTransport(
            route(url, origin: originBase, kind: kind),
            kind: kind,
            log: log,
          );
          final client = HttpClient();
          try {
            await transport.start();
            final path = kind == DiscKind.iso ? '' : 'BDMV/STREAM/00001.m2ts';
            for (var i = 0; i < 32; i++) {
              final offset = baseOffset + i * mib;
              final request = await client.getUrl(
                Uri.parse(
                  '${transport.base}/input?path=${Uri.encodeComponent(path)}',
                ),
              );
              request.headers.set('Range', 'bytes=$offset-${offset + mib - 1}');
              final response = await request.close();
              expect(response.statusCode, 206);
              expect(
                response.headers.value('Content-Range'),
                'bytes $offset-${offset + mib - 1}/$total',
              );
              final bytes = await response.fold<BytesBuilder>(
                BytesBuilder(copy: false),
                (b, d) => b..add(d),
              );
              final result = bytes.takeBytes();
              expect(result.length, mib);
              for (final at in [0, 191, 4096, mib - 1]) {
                expect(result[at], (offset + at) % 251);
              }
            }
            expect(
              calls,
              1,
              reason:
                  '32 consecutive one-MiB reads should share one continuous HTTP response',
            );
            expect(transport.failure, null);
            expect(log.export(), contains('原盘数据就绪'));
            expect(log.export(), contains('读取等待='));
            expect(log.export(), isNot(contains('SYNTHETIC_TOKEN')));
          } finally {
            client.close(force: true);
            await transport.close();
            await origin.close(force: true);
            await external.close(force: true);
            log.dispose();
          }
        }, LoopbackHttpOverrides());
      },
    );
  }

  test(
    'post-open clip failure reaches the playback error handler once and is redacted',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            if (call.method == 'open') return titleData;
            if (call.method == 'size') return 1024;
            if (call.method == 'read') {
              throw PlatformException(
                code: 'disc',
                message:
                    "SocketException: Failed host lookup: 'private.cdn.invalid', address = private.cdn.invalid",
              );
            }
            return null;
          },
        );
        final failures = <String>[];
        final transport = DiscTransport(
          route('https://unused.invalid/film.iso'),
          kind: DiscKind.iso,
          onFailure: failures.add,
        );
        final client = HttpClient();
        try {
          await transport.start();
          for (var i = 0; i < 2; i++) {
            try {
              final response = await (await client.getUrl(
                Uri.parse('${transport.base}/clip/00001.m2ts'),
              )).close();
              await response.drain<void>();
            } on HttpException {
              /* unfinished local response after a failed read */
            }
          }
          expect(failures.length, 1);
          expect(failures.single, contains('SocketException'));
          expect(failures.single, isNot(contains('private.cdn.invalid')));
        } finally {
          client.close(force: true);
          await transport.close();
        }
      }, LoopbackHttpOverrides());
    },
  );

  test(
    'disc selection is retained per account, item and media source',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = AppStore(await SharedPreferences.getInstance());
      final account = syntheticSession();
      await store.saveDiscKind(account, 'film', 'source', DiscKind.iso);
      await store.saveDiscPlaylist(account, 'film', 'source', 12);
      expect(store.discKind(account, 'film', 'source'), DiscKind.iso);
      expect(store.discPlaylist(account, 'film', 'source'), 12);
      expect(store.discPlaylist(account, 'film', 'other'), null);
      expect(
        store.discKind(
          syntheticSession('https://different.invalid'),
          'film',
          'source',
        ),
        null,
      );
      await store.saveDiscKind(account, 'film', 'source', null);
      expect(store.discKind(account, 'film', 'source'), null);
    },
  );
  test(
    'audio label describes decoded codec and channels without inventing Atmos',
    () {
      final text = audioTrackLabel(
        const AudioTrack(
          '1',
          'English',
          'eng',
          codec: 'truehd',
          channelscount: 8,
        ),
      );
      expect(text, contains('Dolby TrueHD'));
      expect(text, contains('8 声道'));
      expect(text, isNot(contains('Atmos')));
    },
  );

  test('BDMV gateway uses an HTTP directory and exact file ranges', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((req) async {
        requests.add(req.uri.path);
        if (req.uri.path == '/disc/BDMV/PLAYLIST/') {
          req.response.write(
            '<a href="00001.mpls">main</a><a href="../">parent</a>',
          );
        } else if (req.uri.path == '/disc/BDMV/index.bdmv') {
          req.response.statusCode = 206;
          req.response.headers.set('Content-Range', 'bytes 0-15/16');
          req.response.add(Uint8List(16));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        DiscTransport.channel,
        (call) async {
          if (call.method == 'open') {
            expect(call.arguments['iso'], false);
            final client = HttpClient();
            try {
              final base = call.arguments['base'];
              final listing = await (await client.getUrl(
                Uri.parse('$base/list?path=BDMV%2FPLAYLIST'),
              )).close();
              expect(
                await listing.transform(utf8.decoder).join(),
                '00001.mpls',
              );
              final req = await client.getUrl(
                Uri.parse('$base/input?path=BDMV%2Findex.bdmv'),
              );
              req.headers.set('Range', 'bytes=0-262143');
              final data = await req.close();
              expect(data.statusCode, 206);
              await data.drain<void>();
            } finally {
              client.close(force: true);
            }
            return titleData;
          }
          return null;
        },
      );
      final url = 'http://127.0.0.1:${server.port}/disc/BDMV/index.bdmv';
      final discRoute = PlaybackRoute(
        url: url,
        sourceId: 'a',
        sessionId: 'b',
        headers: {},
        streams: [],
        discKind: DiscKind.blurayFolder,
        discFolderUrl: url,
      );
      final transport = DiscTransport(discRoute, kind: DiscKind.blurayFolder);
      try {
        expect(await transport.start(), startsWith('edl://'));
        expect(requests, ['/disc/BDMV/PLAYLIST/', '/disc/BDMV/index.bdmv']);
      } finally {
        await transport.close();
        await server.close(force: true);
      }
    }, LoopbackHttpOverrides());
  });

  test(
    'a server ignoring Range produces the real reason and closes the disc session',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((req) async {
          req.response.write('not a partial response');
          await req.response.close();
        });
        var closed = false;
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            if (call.method == 'close') {
              closed = true;
              return null;
            }
            if (call.method == 'open') {
              final client = HttpClient();
              try {
                final req = await client.getUrl(
                  Uri.parse('${call.arguments['base']}/input?path='),
                );
                req.headers.set('Range', 'bytes=0-262143');
                final response = await req.close();
                expect(response.statusCode, 502);
                await response.drain<void>();
              } finally {
                client.close(force: true);
              }
              throw PlatformException(
                code: 'disc',
                message: 'Native read failed',
              );
            }
            return null;
          },
        );
        final transport = DiscTransport(
          route('http://127.0.0.1:${server.port}/disc.iso'),
          kind: DiscKind.iso,
        );
        try {
          await expectLater(
            transport.start(),
            throwsA(
              isA<AppFailure>().having(
                (e) => e.message,
                'actual response',
                contains('HTTP 200'),
              ),
            ),
          );
          expect(closed, true);
        } finally {
          await transport.close();
          await server.close(force: true);
        }
      }, LoopbackHttpOverrides());
    },
  );

  test(
    'closing while native parsing is pending never returns a playable address',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final opening = Completer<void>();
        final finish = Completer<String>();
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            if (call.method == 'open') {
              opening.complete();
              return finish.future;
            }
            return null;
          },
        );
        final transport = DiscTransport(
          route('http://127.0.0.1:9/disc.iso'),
          kind: DiscKind.iso,
        );
        final result = transport.start();
        final assertion = expectLater(
          result,
          throwsA(
            isA<AppFailure>().having(
              (e) => e.message,
              'cancelled',
              contains('退出'),
            ),
          ),
        );
        await opening.future;
        await transport.close();
        finish.complete(titleData);
        await assertion;
      }, LoopbackHttpOverrides());
    },
  );

  test(
    'STRM is an indirection; metadata or resolved target chooses ISO/BDMV',
    () {
      expect(
        discSourceKind({
          'Container': 'strm',
          'VideoType': 'Iso',
          'Path': '/library/title.strm',
        }),
        DiscKind.iso,
      );
      expect(
        discSourceKind({
          'Container': 'strm',
          'Path': '/library/title.strm',
          'DirectStreamUrl': 'https://cdn.invalid/a.iso?sig=x',
        }),
        DiscKind.iso,
      );
      expect(
        discSourceKind({'Path': r'Z:\film\BDMV\index.bdmv'}),
        DiscKind.blurayFolder,
      );
      expect(
        discSourceKind({'Container': 'strm', 'VideoType': 'BluRay'}),
        DiscKind.blurayFolder,
      );
      expect(
        discSourceKind({
          'Path': 'https://cdn.invalid/remux.mkv',
          'Name': 'BluRay Dolby ISO',
        }),
        DiscKind.none,
      );
      expect(discSourceKind({'Path': '/library/title.strm'}), DiscKind.none);
    },
  );
  test('only actual UDF volume signatures trigger response detection', () {
    final bytes = Uint8List(65536);
    bytes.setAll(17 * 2048 + 1, ascii.encode('NSR03'));
    expect(isUdfDiscPrefix(bytes), true);
    expect(isUdfDiscPrefix(ascii.encode('NSR03 fake movie title')), false);
  });
  test(
    'disc byte ranges retain 64 bit offsets and reject malformed ranges',
    () {
      const size = 90 * 1024 * 1024 * 1024;
      expect(discByteRange('bytes=8589934592-8589935600', size), (
        start: 8589934592,
        end: 8589935600,
      ));
      expect(discByteRange('bytes=-100', size), (
        start: size - 100,
        end: size - 1,
      ));
      expect(discByteRange('bytes=99-', 100), (start: 99, end: 99));
      for (final range in [
        'bytes=100-',
        'bytes=-0',
        'bytes=2-1',
        'bytes=1-2,4-5',
        'bytes=-',
      ]) {
        expect(discByteRange(range, 100), null);
      }
    },
  );
  test(
    'EDL preserves playlist order, absolute PTS, trimming and virtual duration',
    () {
      final title = DiscTitle(object((jsonDecode(titleData) as List).first));
      expect(
        title.edl('http://127.0.0.1:1234/a'),
        'edl://!no_chapters;%39%http://127.0.0.1:1234/a/clip/00001.m2ts,600.000000,1.000000;%39%http://127.0.0.1:1234/a/clip/00002.m2ts,1.000000,1.000000',
      );
      expect(title.duration, 180000);
      expect(
        Media.normalizeURI(title.edl('http://127.0.0.1:1234/a')),
        title.edl('http://127.0.0.1:1234/a'),
      );
      expect(
        () => DiscTitle({
          'duration': 90000,
          'clips': [
            {'id': '../secret', 'in': 0, 'out': 90000},
          ],
        }),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test('BDMV root and bounded directory names cannot escape disc tree', () {
    expect(
      discFolderRoot('https://cdn.invalid/film/BDMV/index.bdmv?sig=%2f'),
      'https://cdn.invalid/film/?sig=%2f',
    );
    expect(
      discChildAddress(
        'https://cdn.invalid/film/',
        'BDMV/PLAYLIST',
        directory: true,
      ),
      'https://cdn.invalid/film/BDMV/PLAYLIST/',
    );
    expect(
      discDirectoryEntries(
        '<a href="00001.mpls">one</a><a href="../">up</a><a href="https://evil.invalid/00002.mpls">x</a><a href="00002.mpls?token=secret">x</a>',
      ),
      ['00001.mpls'],
    );
    for (final path in [
      'BDMV/../secret',
      '/BDMV/index.bdmv',
      'BDMV/a%2fb',
      'BDMV/./x',
      'http://evil.invalid',
    ]) {
      expect(validDiscRelativePath(path), false);
    }
  });
  test('signed request target is byte exact on the wire', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final line = Completer<String>();
      final sockets = <Socket>[];
      server.listen((socket) {
        sockets.add(socket);
        final buffer = StringBuffer();
        socket.listen((bytes) {
          buffer.write(ascii.decode(bytes));
          if (!line.isCompleted && buffer.toString().contains('\r\n\r\n')) {
            line.complete(buffer.toString().split('\r\n').first);
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK',
            );
          }
        });
      });
      final client = HttpClient();
      try {
        final res = await (await client.getUrl(
          ExactHttpUri(
            'http://127.0.0.1:${server.port}/%7e/a%2fb.iso?sig=%2f%2B&x=a+b&x=2',
          ),
        )).close();
        await res.drain<void>();
        expect(
          await line.future,
          'GET /%7e/a%2fb.iso?sig=%2f%2B&x=a+b&x=2 HTTP/1.1',
        );
      } finally {
        client.close(force: true);
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      }
    }, LoopbackHttpOverrides());
  });

  test(
    'STRM to disc redirect hands off before any external read and keeps signature',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        const target = 'https://external.invalid/film.iso?sig=%2f%2B&key=a+b';
        server.listen((req) async {
          req.response.statusCode = 302;
          req.response.headers.set('Location', target);
          await req.response.close();
        });
        final base = Uri.parse('http://127.0.0.1:${server.port}');
        final detected = Completer<String>();
        final transport = EmbyOriginTransport(
          route('$base/stream', origin: base, kind: DiscKind.none),
          onDisc: (kind, address) {
            expect(kind, DiscKind.iso);
            detected.complete(address);
          },
        );
        final client = HttpClient();
        try {
          final address = await transport.start();
          final res = await (await client.getUrl(Uri.parse(address))).close();
          expect(res.statusCode, 415);
          await res.drain<void>();
          expect(await detected.future, target);
        } finally {
          client.close(force: true);
          await transport.close();
          await server.close(force: true);
        }
      }, LoopbackHttpOverrides());
    },
  );

  test(
    'disc ranges reuse a redirect target and never refresh or retry a denied target',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final external = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originBase = Uri.parse('http://127.0.0.1:${origin.port}');
        var originRequests = 0, externalRequests = 0;
        final externalPorts = <int>[];
        origin.listen((req) async {
          originRequests++;
          expect(req.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
          req.response.statusCode = 302;
          req.response.headers.set(
            'Location',
            'http://127.0.0.1:${external.port}/disc.iso?generation=$originRequests',
          );
          await req.response.close();
        });
        external.listen((req) async {
          externalRequests++;
          externalPorts.add(req.connectionInfo!.remotePort);
          expect(req.headers.value('x-emby-token'), null);
          expect(req.headers.value('x-emby-authorization'), null);
          expect(req.headers.value('range'), 'bytes=0-15');
          expect(req.uri.queryParameters['generation'], '1');
          if (externalRequests == 3) {
            req.response.statusCode = 403;
          } else {
            req.response.statusCode = 206;
            req.response.headers.set('Content-Range', 'bytes 0-15/96636764160');
            req.response.add(List.generate(16, (i) => i));
          }
          await req.response.close();
        });
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            if (call.method != 'open') return null;
            final client = HttpClient();
            try {
              for (var i = 0; i < 5; i++) {
                final req = await client.getUrl(
                  Uri.parse('${call.arguments['base']}/input?path='),
                );
                req.headers.set('Range', 'bytes=0-15');
                final res = await req.close();
                expect(
                  res.statusCode,
                  i < 2
                      ? 206
                      : i == 2
                      ? 403
                      : 502,
                );
                final bytes = await res.fold<List<int>>(
                  [],
                  (a, b) => a..addAll(b),
                );
                if (i < 2) expect(bytes, List.generate(16, (i) => i));
              }
            } finally {
              client.close(force: true);
            }
            return titleData;
          },
        );
        final transport = DiscTransport(
          route('$originBase/stream', origin: originBase),
          kind: DiscKind.iso,
        );
        try {
          await transport.start();
          expect(originRequests, 1);
          expect(externalRequests, 3);
          expect(
            externalPorts[1],
            externalPorts[0],
            reason: 'sequential chunks should reuse the upstream connection',
          );
          expect(transport.failure, null);
        } finally {
          await transport.close();
          await origin.close(force: true);
          await external.close(force: true);
        }
      }, LoopbackHttpOverrides());
    },
  );

  test(
    'disc gateway isolates auth across redirects and serves seekable clips without a native engine',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final external = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final originBase = Uri.parse('http://127.0.0.1:${origin.port}');
        var originRequests = 0, externalRequests = 0, reads = 0, closes = 0;
        origin.listen((req) async {
          originRequests++;
          expect(req.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
          req.response.statusCode = 302;
          req.response.headers.set(
            'Location',
            'http://127.0.0.1:${external.port}/disc.iso?sig=%2f',
          );
          await req.response.close();
        });
        external.listen((req) async {
          externalRequests++;
          expect(req.headers.value('x-emby-token'), null);
          expect(req.headers.value('x-emby-authorization'), null);
          expect(req.headers.value('user-agent'), 'Synthetic/1');
          expect(req.headers.value('range'), 'bytes=8589934592-8589938687');
          req.response.statusCode = 206;
          req.response.headers.set(
            'Content-Range',
            'bytes 8589934592-8589938687/96636764160',
          );
          req.response.add(Uint8List(4096));
          await req.response.close();
        });
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          DiscTransport.channel,
          (call) async {
            switch (call.method) {
              case 'open':
                final client = HttpClient();
                try {
                  final req = await client.getUrl(
                    Uri.parse('${call.arguments['base']}/input?path='),
                  );
                  req.headers.set('Range', 'bytes=8589934592-8589938687');
                  final res = await req.close();
                  expect(res.statusCode, 206);
                  expect(
                    (await res.fold<List<int>>(
                      [],
                      (all, bytes) => all..addAll(bytes),
                    )).length,
                    4096,
                  );
                } finally {
                  client.close(force: true);
                }
                return titleData;
              case 'size':
                return 1024;
              case 'read':
                reads++;
                return Uint8List.fromList(
                  List.generate(
                    call.arguments['length'] as int,
                    (i) => (i + (call.arguments['offset'] as int)) % 251,
                  ),
                );
              case 'close':
                closes++;
                return null;
            }
            return null;
          },
        );
        final transport = DiscTransport(
          route('$originBase/stream', origin: originBase),
          kind: DiscKind.iso,
        );
        final client = HttpClient();
        try {
          final edl = await transport.start();
          expect(edl, contains('600.000000,1.000000'));
          final req = await client.getUrl(
            Uri.parse('${transport.base}/clip/00001.m2ts'),
          );
          req.headers.set('Range', 'bytes=800-899');
          final res = await req.close();
          expect(res.statusCode, 206);
          expect(res.headers.value('Content-Range'), 'bytes 800-899/1024');
          final bytes = await res.fold<List<int>>(
            [],
            (all, bytes) => all..addAll(bytes),
          );
          expect(bytes, List.generate(100, (i) => (800 + i) % 251));
          final head = await (await client.headUrl(
            Uri.parse('${transport.base}/clip/00002.m2ts'),
          )).close();
          await head.drain<void>();
          expect(head.contentLength, 1024);
          expect(reads, 1);
          final missing = await (await client.getUrl(
            Uri.parse('${transport.base}/clip/99999.m2ts'),
          )).close();
          expect(missing.statusCode, 404);
          await missing.drain<void>();
          expect(originRequests, 1);
          expect(externalRequests, 1);
        } finally {
          client.close(force: true);
          await transport.close();
          await origin.close(force: true);
          await external.close(force: true);
        }
        expect(closes, 1);
      }, LoopbackHttpOverrides());
    },
  );
}
