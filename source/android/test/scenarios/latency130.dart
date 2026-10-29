// ignore_for_file: avoid_print
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:yingyu/playback/latency_probe.dart';
import 'package:yingyu/playback/http_trace.dart';
import 'package:yingyu/core/log.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;

void main() {
  test(
    'measure native video re-enable and explicit HDR-refill seek sequence',
    () async {
      MediaKit.ensureInitialized(
        libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
      );
      final player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
      );
      final native = player.platform as NativePlayer;
      final clock = Stopwatch()..start();
      final rows = <String>[];
      final sub = native.playbackEvents.listen((e) {
        if (e.outputChanged || e.restarted) {
          rows.add(
            '${clock.elapsedMilliseconds} id=${e.id} restart=${e.restarted}',
          );
        }
      });
      try {
        for (final e in {
          'vo': 'null',
          'ao': 'null',
          'vid': 'auto',
          'sub-auto': 'no',
          'sid': '1',
          'demuxer-mkv-subtitle-preroll-secs': '10',
        }.entries) {
          await native.setProperty(e.key, e.value);
        }
        await player.open(
          Media(
            'D:/Temp/yingyu-playback128-probe/hdr.mkv',
            start: const Duration(seconds: 3),
          ),
          play: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
        rows.clear();
        clock.reset();
        await native.setOutputProperty('vid', 'no');
        await native.setOutputProperty('vid', '1');
        await native.setOutputProperty('vid', 'auto');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        print('VIDEO-REENABLE: $rows');
        expect(
          rows.any((r) => r.contains('id=${mpv.mpv_event_id.MPV_EVENT_SEEK} ')),
          false,
        );
        rows.clear();
        clock.reset();
        await native.refreshOutputFrame('3.000000', epoch: native.outputEpoch);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        print(
          'EXPLICIT-REFILL: $rows; target=${await native.getProperty("time-pos")}',
        );
        expect(await native.getProperty('time-pos'), '3.000000');
        expect(
          rows
              .where(
                (r) => r.contains('id=${mpv.mpv_event_id.MPV_EVENT_SEEK} '),
              )
              .length,
          1,
        );
        expect(rows.any((r) => r.contains('restart=true')), true);
      } finally {
        await sub.cancel();
        await player.dispose();
        // media-kit retires the native context after five seconds. Let the
        // FFmpeg process-wide callback release its previous owner before the
        // next independent reference-player scenario begins.
        await Future<void>.delayed(const Duration(milliseconds: 5200));
      }
    },
  );
  test(
    'actual reference MPV captures post-opening HTTP seek and restores logging',
    () async {
      MediaKit.ensureInitialized(
        libmpv: 'D:/Temp/yingyu-playback128-probe/mpv/libmpv-2.dll',
      );
      final body = File(
        'D:/Temp/yingyu-playback128-probe/latency130.mkv',
      ).readAsBytesSync();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final serverSub = server.listen((r) async {
        requests++;
        final range = RegExp(
          r'^bytes=(\d+)-(\d*)$',
        ).firstMatch(r.headers.value('range') ?? '');
        final a = range == null ? 0 : int.parse(range[1]!);
        final b = range == null || range[2]!.isEmpty
            ? body.length - 1
            : int.parse(range[2]!);
        await Future<void>.delayed(const Duration(milliseconds: 180));
        if (a < 0 || a >= body.length || b < a) {
          r.response.statusCode = 416;
          await r.response.close();
          return;
        }
        r.response.headers.set('Accept-Ranges', 'bytes');
        if (range != null) {
          r.response.statusCode = 206;
          r.response.headers.set('Content-Range', 'bytes $a-$b/${body.length}');
        }
        r.response.contentLength = b - a + 1;
        try {
          r.response.add(body.sublist(a, b + 1));
          await r.response.close();
        } catch (_) {
          /* A native range seek can retire the response. */
        }
      });
      final player = Player(
        configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
      );
      final native = player.platform as NativePlayer;
      final address =
          'http://127.0.0.1:${server.port}/synthetic.mkv?token=PRIVATE';
      final log = DiagnosticLog();
      final rows = <String>[];
      final probe = PlaybackLatencyProbe(
        read: native.getProperty,
        write: native.setProperty,
        request: (level) {
          final p = level.toNativeUtf8();
          try {
            return native.mpv.mpv_request_log_messages(native.ctx, p.cast());
          } finally {
            calloc.free(p);
          }
        },
        record: rows.add,
        interval: const Duration(milliseconds: 50),
        limit: const Duration(seconds: 3),
      );
      final prefixes = <String, int>{};
      final logSub = player.stream.log.listen((v) {
        prefixes.update(v.prefix, (n) => n + 1, ifAbsent: () => 1);
        probe.add(v.prefix, v.text);
      });
      final eventSub = native.playbackEvents.listen(
        (e) => probe.nativeEvent(
          seek: e.id == mpv.mpv_event_id.MPV_EVENT_SEEK,
          restart: e.restarted,
        ),
      );
      try {
        for (final o in {
          'vo': 'null',
          'ao': 'null',
          'vid': 'auto',
          'sub-auto': 'no',
          'sid': '1',
          'cache': 'no',
          'load-unsafe-playlists': 'yes',
          'demuxer-readahead-secs': '0',
          'stream-buffer-size': '4096',
          'demuxer-mkv-subtitle-preroll-secs': '10',
        }.entries) {
          await native.setProperty(o.key, o.value);
        }
        await player.open(
          Media('ffmpeg://$address', start: const Duration(seconds: 8)),
          play: false,
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        for (var i = 0; i < 80; i++) {
          if (await native.getProperty('seeking') == 'no' &&
              await native.getProperty('time-pos') == '8.000000') {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(await native.getProperty('seeking'), 'no');
        final saved = await native.getProperty('options/msg-level');
        final http = HttpPlaybackTrace(
          log: log,
          address: address,
          headers: const {},
          phase: 'seek',
        );
        probe.begin(
          phase: 'seek',
          target: const Duration(seconds: 3),
          producer: true,
          http: http.add,
          finishHttp: http.finish,
        );
        // Diagnostic setup is deliberately awaited only by this observation test,
        // so a fast local response cannot outrun protocol subscription.
        await Future<void>.delayed(const Duration(milliseconds: 100));

        final old = requests;
        final clock = Stopwatch()..start();
        await player.seek(const Duration(seconds: 3));
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (rows.any((r) => r.contains('native_restart')) &&
              await native.getProperty('seeking') == 'no') {
            break;
          }
        }
        await probe.close();
        expect(await native.getProperty('time-pos'), '3.000000');
        expect(await native.getProperty('options/msg-level'), saved);
        expect(rows.any((r) => r.contains('native_seek')), true);
        expect(rows.any((r) => r.contains('native_restart')), true);
        expect(requests, greaterThan(old));
        final exported = log.export();
        print(
          'TRACE-OBSERVATION: prefixes=$prefixes rows=$rows export=$exported',
        );
        expect(exported, contains('[seek]'));
        expect(exported, contains('HTTP 206'));
        expect(exported, contains('请求至响应='));
        expect(exported, contains('响应正文=MPV 未提供'));
        expect(exported, isNot(contains('PRIVATE')));
        print(
          'POST-OPEN SEEK requests=${requests - old} elapsed_ms=${clock.elapsedMilliseconds}; $rows; $exported',
        );
      } finally {
        await probe.close();
        await logSub.cancel();
        await eventSub.cancel();
        await player.dispose();
        await server.close(force: true);
        await serverSub.cancel();
        log.dispose();
      }
    },
  );
}
