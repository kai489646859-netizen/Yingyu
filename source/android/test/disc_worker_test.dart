import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/disc_worker.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route, titleData;

const _mib = 1048576;

// Both the synthetic upstream and consumer run outside the test/UI isolate.
// Deliberately blocking that isolate cannot inadvertently block the fixture.
Future<void> _fixture(SendPort parent) async {
  final commands = ReceivePort();
  final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final media = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var entries = 0, sources = 0, leakedAuth = false, badSignature = false;
  var closing = false;
  final work = <Future<void>>[];
  origin.listen((r) async {
    entries++;
    if (r.headers.value('x-emby-token') != 'SYNTHETIC_TOKEN') leakedAuth = true;
    r.response.statusCode = 302;
    r.response.headers.set(
      'location',
      'http://127.0.0.1:${media.port}/film.iso?sig=%2f%2B&x=a+b&x=2',
    );
    await r.response.close();
  });
  Future<void> serve(HttpRequest r) async {
    sources++;
    leakedAuth |=
        r.headers.value('x-emby-token') != null ||
        r.headers.value('x-emby-authorization') != null;
    badSignature |=
        r.requestedUri.query !=
        Uri.parse('http://synthetic/film.iso?sig=%2f%2B&x=a+b&x=2').query;
    final span = discByteRange(r.headers.value('range'), 128 * _mib)!;
    r.response.statusCode = 206;
    r.response.headers.set(
      'content-range',
      'bytes ${span.start}-${span.end}/${128 * _mib}',
    );
    r.response.headers.set('etag', '"synthetic"');
    r.response.contentLength = span.end - span.start + 1;
    try {
      for (var at = span.start; at <= span.end; at += 65536) {
        if (closing) return;
        final n = (span.end - at + 1).clamp(0, 65536);
        r.response.add(Uint8List(n)..fillRange(0, n, at ~/ 65536 % 251));
        await r.response.flush();
        if (at % _mib == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }
      await r.response.close();
    } on HttpException {
      /* expected on cancelled prefetch */
    } on SocketException {
      /* expected on cancelled prefetch */
    }
  }

  media.listen((r) {
    final job = serve(r);
    work.add(job);
    unawaited(job);
  });
  commands.listen((dynamic value) async {
    final command = value as List;
    final reply = command.last as SendPort;
    if (command[0] == 'read') {
      final client = HttpClient();
      try {
        // This guarantees the first request occurs during the intentional UI
        // block, not during preparation before the test starts measuring.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        var checked = 0;
        for (var at = 0; at < 8 * _mib; at += _mib) {
          final req = await client.getUrl(
            Uri.parse('${command[1]}/input?path='),
          );
          req.headers.set('range', 'bytes=$at-${at + _mib - 1}');
          final response = await req.close();
          if (response.statusCode != 206) throw StateError('bad range');
          var count = 0;
          await for (final bytes in response) {
            for (var i = 0; i < bytes.length; i++) {
              if (bytes[i] != (at + count + i) ~/ 65536 % 251) {
                throw StateError('bad byte');
              }
            }
            count += bytes.length;
          }
          if (count != _mib) throw StateError('truncated');
          checked += count;
        }
        reply.send({
          'finished_us': DateTime.now().microsecondsSinceEpoch,
          'bytes': checked,
          'entries': entries,
          'sources': sources,
          'leaked_auth': leakedAuth,
          'bad_signature': badSignature,
        });
      } catch (_) {
        reply.send({'error': 'synthetic transfer failed'});
      } finally {
        client.close(force: true);
      }
    } else if (command[0] == 'close') {
      closing = true;
      await origin.close(force: true);
      await media.close(force: true);
      await Future.wait(work);
      reply.send(true);
      commands.close();
    }
  });
  parent.send([commands.sendPort, 'http://127.0.0.1:${origin.port}/entry.iso']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final worker in [false, true]) {
    for (final speed in [2.0, 3.0]) {
      test(
        '${worker ? "worker" : "direct"} $speed data plane with a busy UI isolate',
        () async {
          await HttpOverrides.runWithHttpOverrides(() async {
            final messages = ReceivePort();
            final actor = await Isolate.spawn(_fixture, messages.sendPort);
            final ready = await messages.first as List;
            messages.close();
            final commands = ready[0] as SendPort;
            final source = ready[1] as String;
            String? base;
            final nativeCalls = <String>[];
            Future<Object?> native(
              String method,
              Map<String, Object?> args,
            ) async {
              nativeCalls.add(method);
              if (method == 'open') {
                base = args['base'] as String;
                return titleData;
              }
              if (method == 'output') return base;
              if (method == 'outputStatus') {
                return <Object?, Object?>{'failed': false};
              }
              if (method == 'close') return null;
              fail('Unexpected video-data control call: $method');
            }

            final playbackRoute = route(source, origin: Uri.parse(source));
            final transport = worker
                ? DiscWorkerTransport(
                    playbackRoute,
                    kind: DiscKind.iso,
                    nativeInvoke: native,
                  )
                : DiscTransport(
                    playbackRoute,
                    kind: DiscKind.iso,
                    backgroundOutput: true,
                    nativeInvoke: native,
                  );
            final reply = ReceivePort();
            try {
              await transport.start();
              transport.setSpeed(speed);
              commands.send(['read', base, reply.sendPort]);
              final clock = Stopwatch()..start();
              while (clock.elapsedMilliseconds < 1500) {
                /* intentional UI work */
              }
              final unblock = DateTime.now().microsecondsSinceEpoch;
              final result =
                  (await reply.first.timeout(const Duration(seconds: 8)))
                      as Map;
              expect(result['error'], null);
              expect(result['bytes'], 8 * _mib);
              expect(result['entries'], 1);
              expect(result['sources'], greaterThanOrEqualTo(1));
              expect(result['leaked_auth'], false);
              expect(result['bad_signature'], false);
              final independent = (result['finished_us'] as int) < unblock;
              expect(
                independent,
                worker,
                reason:
                    'only the worker data plane may finish while the UI cannot process events',
              );
              expect(nativeCalls, isNot(contains('read')));
              await transport.refreshReadHealth();
              expect(transport.failure, null);
              Directory('build').createSync(recursive: true);
              File(
                'build/worker-ui-${worker ? "worker" : "direct"}-${speed.toInt()}.json',
              ).writeAsStringSync(
                jsonEncode({
                  ...result,
                  'finished_during_ui_block': independent,
                  'ui_block_ms': 1500,
                  'speed': speed,
                  'scope':
                      'Synthetic IO only; no JNI, decoder, device or real media.',
                }),
              );
            } finally {
              reply.close();
              await transport.close();
              final ended = ReceivePort();
              commands.send(['close', ended.sendPort]);
              await ended.first.timeout(const Duration(seconds: 5));
              ended.close();
              actor.kill();
            }
          }, LoopbackHttpOverrides());
        },
        timeout: const Timeout(Duration(seconds: 20)),
      );
    }
  }

  test(
    'closing during open cancels the native session and ignores a late title',
    () async {
      final opening = Completer<Object?>(), entered = Completer<void>();
      var closed = 0, failures = 0;
      String? base;
      final transport = DiscWorkerTransport(
        route('http://127.0.0.1:1/synthetic.iso'),
        kind: DiscKind.iso,
        onFailure: (_) => failures++,
        nativeInvoke: (method, args) async {
          if (method == 'open') {
            base = args['base'] as String;
            entered.complete();
            return opening.future;
          }
          if (method == 'close') {
            closed++;
            opening.complete(titleData);
          }
          return null;
        },
      );
      final started = transport.start();
      final failed = expectLater(started, throwsA(isA<AppFailure>()));
      await entered.future;
      await transport.close();
      await failed;
      expect(closed, 1);
      expect(failures, 0);
      expect(transport.selected, null);
      await expectLater(
        Socket.connect(
          '127.0.0.1',
          Uri.parse(base!).port,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<SocketException>()),
      );
    },
  );

  test('native failure and worker logs preserve secret redaction', () async {
    final log = DiagnosticLog();
    final failures = <String>[];
    final transport = DiscWorkerTransport(
      PlaybackRoute(
        url: 'http://127.0.0.1:1/synthetic.iso',
        sourceId: 'synthetic',
        sessionId: 'synthetic',
        headers: {},
        streams: [],
        diagnosticSecrets: ['PRIVATE_SECRET'],
      ),
      kind: DiscKind.iso,
      log: log,
      onFailure: failures.add,
      nativeInvoke: (method, args) async {
        if (method == 'open') {
          throw StateError(
            'PRIVATE_SECRET https://private.invalid/?token=PRIVATE_SECRET',
          );
        }
        return null;
      },
    );
    try {
      await expectLater(transport.start(), throwsA(isA<AppFailure>()));
      expect(failures, hasLength(1));
      expect(
        '${failures.single}${log.export()}',
        isNot(contains('PRIVATE_SECRET')),
      );
      expect(
        '${failures.single}${log.export()}',
        isNot(contains('private.invalid')),
      );
    } finally {
      await transport.close();
      log.dispose();
    }
  });

  test('closing immediately never publishes a late ready session', () async {
    var opens = 0, failures = 0;
    final transport = DiscWorkerTransport(
      route('http://127.0.0.1:1/synthetic.iso'),
      kind: DiscKind.iso,
      onFailure: (_) => failures++,
      nativeInvoke: (method, args) async {
        if (method == 'open') opens++;
        return null;
      },
    );
    final started = expectLater(transport.start(), throwsA(isA<AppFailure>()));
    await transport.close();
    await started;
    await transport.close();
    expect(opens, 0);
    expect(failures, 0);
    expect(transport.selected, null);
  });

  test('background output failure reaches the UI once after opening', () async {
    String? base;
    final failed = Completer<String>();
    var calls = 0;
    final transport = DiscWorkerTransport(
      route('http://127.0.0.1:1/synthetic.iso'),
      kind: DiscKind.iso,
      onFailure: (message) {
        calls++;
        if (!failed.isCompleted) failed.complete(message);
      },
      nativeInvoke: (method, args) async {
        if (method == 'open') {
          base = args['base'] as String;
          return titleData;
        }
        if (method == 'output') return base;
        if (method == 'outputStatus') return <Object?, Object?>{'failed': true};
        return null;
      },
    );
    try {
      await transport.start();
      expect(
        await failed.future.timeout(const Duration(seconds: 5)),
        contains('读取失败'),
      );
      expect(calls, 1);
      expect(transport.failure, isNotNull);
    } finally {
      await transport.close();
    }
  });
}
