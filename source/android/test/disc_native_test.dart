import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_native.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/disc_worker.dart';
import 'core_test.dart' show LoopbackHttpOverrides;
import 'disc_test.dart' show route;
import 'host/disc_open/current.dart' as current;
import 'host/disc_open/previous.dart' as previous;
import 'host/disc_open/submitted_media.dart';

final _library = Platform.environment['YINGYU_NATIVE_DISC_LIBRARY'];
final _fixture = Platform.environment['YINGYU_NATIVE_DISC_FIXTURE'];
const _mib = 1048576;

class _Harness {
  _Harness() : library = DynamicLibrary.open(_library!);
  final DynamicLibrary library;
  late final _open = library
      .lookupFunction<
        Void Function(Pointer<Utf8>, Int64, Pointer<Void>),
        void Function(Pointer<Utf8>, int, Pointer<Void>)
      >('yt_open');
  late final _read = library
      .lookupFunction<
        Void Function(Int64, Int64, Int32, Int64, Pointer<Void>),
        void Function(int, int, int, int, Pointer<Void>)
      >('yt_read');
  late final _origin = library
      .lookupFunction<
        Void Function(Pointer<Utf8>, Int32, Int64, Pointer<Void>),
        void Function(Pointer<Utf8>, int, int, Pointer<Void>)
      >('yt_open_from_origin');
  Future<List> fromOrigin(String address, bool playlist) async {
    final port = ReceivePort(), uri = address.toNativeUtf8();
    try {
      _origin(
        uri,
        playlist ? 1 : 0,
        port.sendPort.nativePort,
        NativeApi.postCObject.cast(),
      );
      return await port.first.timeout(const Duration(seconds: 20)) as List;
    } finally {
      calloc.free(uri);
      port.close();
    }
  }

  late final cancel = library
      .lookupFunction<Void Function(Int64), void Function(int)>('yt_cancel');
  late final _once = library
      .lookupFunction<
        Void Function(Int64, Int64, Int32, Int64, Pointer<Void>),
        void Function(int, int, int, int, Pointer<Void>)
      >('yt_read_once');
  late final close = library
      .lookupFunction<Void Function(Int64), void Function(int)>('yt_close');
  late final sessions = library
      .lookupFunction<Int32 Function(), int Function()>('yt_sessions');
  late final requests = library
      .lookupFunction<Int32 Function(), int Function()>('yt_requests');
  Future<List> open(String address) async {
    final port = ReceivePort(), uri = address.toNativeUtf8();
    try {
      _open(uri, port.sendPort.nativePort, NativeApi.postCObject.cast());
      return await port.first.timeout(const Duration(seconds: 20)) as List;
    } finally {
      calloc.free(uri);
      port.close();
    }
  }

  Future<List> read(int id, int at, int length, {bool once = false}) async {
    final port = ReceivePort();
    try {
      (once ? _once : _read)(
        id,
        at,
        length,
        port.sendPort.nativePort,
        NativeApi.postCObject.cast(),
      );
      return await port.first.timeout(const Duration(seconds: 20)) as List;
    } finally {
      port.close();
    }
  }
}

class _Source {
  late HttpServer server;
  var count = 0, entries = 0, media = 0;
  bool reject = false, slow = false, malformed = false, prefixOnly = false;
  Completer<void>? blocked;
  final stalls = <HttpResponse>[];
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      count++;
      try {
        var name = Uri.decodeComponent(r.uri.path).substring(1);
        if (name == 'entry') {
          entries++;
          expect(r.headers.value('x-emby-token'), 'SYNTHETIC_TOKEN');
          r.response.statusCode = 302;
          r.response.headers.set(
            'location',
            '$base/synthetic.iso?signature=%2f%2B&x=a+b&x=2',
          );
          await r.response.close();
          return;
        }
        // Tests use the same loopback origin; separate-origin auth is covered
        // by the shared transport's existing signed URL and redirect tests.
        final path = File('$_fixture/$name');
        if (!await path.exists()) {
          final dir = Directory('$_fixture/$name');
          if (await dir.exists()) {
            r.response.write(
              await dir
                  .list()
                  .map(
                    (f) =>
                        '<a href="${f.uri.pathSegments.where((s) => s.isNotEmpty).last}">entry</a>',
                  )
                  .join(),
            );
          } else {
            r.response.statusCode = 404;
          }
          await r.response.close();
          return;
        }
        media++;
        if (reject) {
          r.response.statusCode = 503;
          await r.response.close();
          return;
        }
        if (slow) {
          stalls.add(r.response);
          if (blocked?.isCompleted == false) blocked!.complete();
          return;
        }
        final size = await path.length();
        final span = discByteRange(r.headers.value('range'), size);
        if (span == null) {
          r.response.statusCode = 416;
          await r.response.close();
          return;
        }
        r.response.statusCode = 206;
        r.response.headers.set('etag', '"synthetic-immutable"');
        r.response.headers.set(
          'content-range',
          'bytes ${malformed ? span.start + 1 : span.start}-${span.end}/$size',
        );
        r.response.contentLength = span.end - span.start + 1;
        if (prefixOnly && span.end - span.start > _mib) {
          // Reserve the held tail before publishing bytes: the native reader
          // may return its prefix before addStream/flush completes here.
          stalls.add(r.response);
          await r.response.addStream(
            path.openRead(span.start, span.start + 262144),
          );
          await r.response.flush();
          return;
        }
        await r.response.addStream(path.openRead(span.start, span.end + 1));
        await r.response.close();
      } on HttpException {
        /* cancelled fixture response */
      } on SocketException {
        /* cancelled fixture response */
      }
    });
  }

  String get base => 'http://127.0.0.1:${server.port}';
  Future<void> close() async {
    for (final response in stalls) {
      response.deadline = Duration.zero;
    }
    await server.close(force: true);
  }
}

void _bytes(List value, int at, int length, {int seed = 0}) {
  expect(value[0], length);
  final data = value[1] as Uint8List;
  expect(data.length, length);
  // Every byte checked, including page/sector boundaries and partial tails.
  for (var n = 0; n < data.length; n++) {
    if (data[n] != ((at + n) ~/ 65536 + seed) % 251) {
      fail('wrong byte at ${at + n}: ${data[n]}');
    }
  }
}

void main() {
  final available = _library != null && _fixture != null;
  group(
    'actual native disc adapter and VideoLAN synthetic files',
    () {
      late _Harness native;
      late _Source source;
      DiscWorkerTransport? transport;
      final streams = <int>[];
      setUp(() async {
        HttpOverrides.global = LoopbackHttpOverrides();
        native = _Harness();
        source = _Source();
        await source.start();
      });
      tearDown(() async {
        await transport?.close();
        transport = null;
        for (final id in streams) {
          native.close(id);
        }
        streams.clear();
        await source.close();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(native.sessions(), 0);
        expect(native.requests(), 0);
        HttpOverrides.global = null;
      });
      Future<String> start({bool iso = true}) async {
        transport = DiscWorkerTransport(
          route(
            '${source.base}/${iso ? 'entry' : 'BDMV/index.bdmv'}',
            origin: Uri.parse(source.base),
          ),
          kind: iso ? DiscKind.iso : DiscKind.blurayFolder,
          directNative: true,
          nativeLibraryPath: _library,
        );
        return transport!.start();
      }

      Future<int> open(String name) async {
        final result = await native.open('${transport!.base}/clip/$name.m2ts');
        expect(result[1], 0);
        expect(result[2], 64 * _mib);
        final id = result[0] as int;
        streams.add(id);
        return id;
      }

      test(
        'canonical ISO resolves once across worker and parses real UDF',
        () async {
          final currentRoute = PlaybackRoute(
            url: '${source.base}/entry',
            sourceId: 'synthetic-disc',
            sessionId: 'synthetic-play',
            headers: {},
            streams: [],
            discKind: DiscKind.iso,
            serverBase: Uri.parse(source.base),
            sameOriginHeaders: {'X-Emby-Token': 'SYNTHETIC_TOKEN'},
          );
          transport = DiscWorkerTransport(
            currentRoute,
            kind: DiscKind.iso,
            directNative: true,
            nativeLibraryPath: _library,
          );
          await transport!.start();
          expect(source.entries, 1);
          expect(currentRoute.playMethod, 'DirectStream');
          final reader = await open('00001');
          _bytes(await native.read(reader, 0, 131072), 0, 131072);
        },
      );

      for (final iso in [true, false]) {
        test(
          '${iso ? "ISO" : "BDMV"} entry replay: old gate rejects, corrected direct entry reads',
          () async {
            final edl = await start(iso: iso);
            final media = submittedMedia(
              edl,
              transport,
              transport!.route,
              const Duration(milliseconds: 1095541),
            );
            final oldPlayer = previous.ReplayPlayer(),
                newPlayer = current.ReplayPlayer();
            addTearDown(oldPlayer.close);
            addTearDown(newPlayer.close);
            await oldPlayer.open(media, play: false);
            await newPlayer.open(media, play: false);
            expect(oldPlayer.target, edl);
            expect(newPlayer.target, edl);
            expect(oldPlayer.load.first, 'loadlist');
            expect(newPlayer.load.first, 'loadfile');
            final uri = '${transport!.base}/clip/00001.m2ts';
            final before = source.count;
            final rejected = await native.fromOrigin(
              uri,
              oldPlayer.load.first == 'loadlist',
            );
            expect(rejected[0], 0);
            expect(rejected[1], lessThan(0));
            expect(
              source.count,
              before,
              reason: 'MPV rejects before any clip IO',
            );
            final opened = await native.fromOrigin(
              uri,
              newPlayer.load.first == 'loadlist',
            );
            expect(opened[1], 0);
            final id = opened[0] as int;
            streams.add(id);
            _bytes(await native.read(id, 0, 65536), 0, 65536);
            _bytes(
              await native.read(id, 3 * _mib + 17, 65536),
              3 * _mib + 17,
              65536,
            );
            Directory('build').createSync(recursive: true);
            File(
              'build/disc-open-${iso ? "iso" : "bdmv"}.json',
            ).writeAsStringSync(
              jsonEncode({
                'old_command': oldPlayer.load.first,
                'new_command': newPlayer.load.first,
                'old_gate_rejected': true,
                'new_native_bytes_checked': 131072,
                'actual_production_open_method': true,
                'actual_pinned_mpv_origin_function': true,
                'actual_native_callback_and_videolan': true,
                'mpv_player_loaded': false,
                'real_media': false,
              }),
            );
          },
        );
        test(
          '${iso ? 'UDF ISO' : 'BDMV directory'} parses real playlist and exact clip bytes',
          () async {
            final edl = await start(iso: iso);
            expect(edl, contains('yingyu-disc://'));
            expect(edl, isNot(contains('127.0.0.1')));
            expect(transport!.selected!.duration, 8100000);
            expect(transport!.selected!.clips.length, 2);
            expect(edl, contains(',10.000000,60.000000'));
            expect(edl, contains(',2.000000,30.000000'));
            final first = await open('00001'), second = await open('00002');
            _bytes(
              await native.read(first, 192 * 7 + 13, 2 * _mib + 91),
              192 * 7 + 13,
              2 * _mib + 91,
            );
            _bytes(
              await native.read(second, 1048501, 192 * 97),
              1048501,
              192 * 97,
              seed: 37,
            );
          },
        );
      }
      for (final speed in [2.0, 3.0]) {
        test(
          'native sustained 64 MiB transfer with $speed speed and hold restore',
          () async {
            await start();
            transport!.setSpeed(speed);
            final id = await open('00001');
            final clock = Stopwatch()..start();
            for (var at = 0; at < 64 * _mib; at += 4 * _mib) {
              _bytes(await native.read(id, at, 4 * _mib), at, 4 * _mib);
              if (at == 8 * _mib) transport!.setSpeed(3);
              if (at == 12 * _mib) transport!.setSpeed(speed);
            }
            await transport!.refreshReadHealth();
            expect(transport!.readHealth, contains('本机 HTTP 转发=0'));
            expect(transport!.readHealth, contains('Java 媒体数组=0'));
            expect(source.entries, 1);
            final report = File('build/native-chain-${speed.toInt()}.json');
            await report.parent.create(recursive: true);
            await report.writeAsString(
              jsonEncode({
                'bytes': 64 * _mib,
                'elapsed_ms': clock.elapsedMilliseconds,
                'speed': speed,
                'real_libbluray': true,
                'real_udfread': true,
                'synthetic_only': true,
                'mpv_player_loaded': false,
                'entry_requests': source.entries,
                'health': transport!.readHealth,
              }),
            );
          },
        );
      }
      test(
        'exact backward/forward/EOF seeks and repeated clip cookies',
        () async {
          await start();
          final a = await open('00001'), b = await open('00001');
          for (final at in [
            48 * _mib + 17,
            23,
            16 * _mib - 5,
            64 * _mib - 19,
            0,
          ]) {
            transport!.resetReadAhead();
            final length = (64 * _mib - at).clamp(0, 65591);
            _bytes(await native.read(a, at, length), at, length);
            _bytes(await native.read(b, 123, 799), 123, 799);
          }
          expect((await native.read(a, 64 * _mib, 1))[0], 0);
          expect((await native.read(a, 64 * _mib + 1, 1))[0], -1);
          expect((await native.read(a, -1, 1))[0], -1);
        },
      );
      test('unselected clip and path traversal cannot open', () async {
        await start();
        for (final name in [
          '99999.m2ts',
          '../00001.m2ts',
          '00001.m2ts?other',
          '00001.m2ts/extra',
        ]) {
          expect((await native.open('${transport!.base}/clip/$name'))[0], 0);
        }
      });
      test(
        'first native callback returns available prefix while HTTP tail is held',
        () async {
          await start();
          final id = await open('00001');
          source.prefixOnly = true;
          final data = await native
              .read(id, 32 * _mib + 17, _mib, once: true)
              .timeout(const Duration(seconds: 2));
          _bytes(data, 32 * _mib + 17, 65536);
          expect(source.stalls, isNotEmpty);
        },
      );
      test(
        'stream cancellation wakes blocked native read; new stream stays usable',
        () async {
          await start();
          final id = await open('00001');
          source.slow = true;
          source.blocked = Completer<void>();
          final pending = native.read(id, 40 * _mib + 11, 65536);
          await source.blocked!.future.timeout(const Duration(seconds: 10));
          final watch = Stopwatch()..start();
          native.cancel(id);
          expect((await pending)[0], -1);
          expect(watch.elapsedMilliseconds, lessThan(1500));
          source.slow = false;
          final other = await open('00002');
          transport!.resetReadAhead();
          _bytes(await native.read(other, 0, 65536), 0, 65536, seed: 37);
        },
      );
      test(
        'close during source wait wakes read and ignores late native reply',
        () async {
          await start();
          final id = await open('00001');
          source.slow = true;
          source.blocked = Completer<void>();
          final pending = native.read(id, 40 * _mib + 11, 65536);
          await source.blocked!.future.timeout(const Duration(seconds: 10));
          await transport!.close();
          expect((await pending)[0], -1);
          DiscNativeApi(
            libraryPath: _library,
          ).reply(9223372036854770000, 0, 1, nullptr, 0);
          expect((await native.read(id, 0, 1))[0], -1);
        },
      );
      test(
        'close while native disc metadata is opening settles startup',
        () async {
          source.slow = true;
          source.blocked = Completer<void>();
          final opening = start();
          final failure = expectLater(opening, throwsA(isA<AppFailure>()));
          await source.blocked!.future.timeout(const Duration(seconds: 10));
          await transport!.close();
          await failure;
        },
      );
      test('mismatched metadata byte range fails without fake title', () async {
        source.malformed = true;
        await expectLater(start(), throwsA(isA<AppFailure>()));
      });
      test(
        'remote failure never becomes successful EOF or infinite retry',
        () async {
          await start();
          final id = await open('00001');
          final before = source.count;
          source.reject = true;
          expect((await native.read(id, 40 * _mib + 11, 65536))[0], -1);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(source.count - before, lessThanOrEqualTo(2));
        },
      );
    },
    skip: available
        ? false
        : 'Build host native adapter and synthetic fixtures first',
  );
}
