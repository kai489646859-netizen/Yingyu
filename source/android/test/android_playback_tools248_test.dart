import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yingyu/core/app_update.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/playback/danmaku_correction.dart';
import 'package:yingyu/playback/danmaku_preferences.dart';
import 'package:yingyu/playback/danmaku_sources.dart';
import 'package:yingyu/playback/playback_report.dart';
import 'package:yingyu/version.dart';

const payload = [1, 3, 5, 7, 9];
final nextVersion = () {
  final components = appVersion.split('.');
  components[2] = '${int.parse(components[2]) + 1}';
  return components.join('.');
}();
final apkPath =
    'https://github.com/kai489646859-netizen/Yingyu/releases/download/android-v$nextVersion/Yingyu-$nextVersion.apk';
final apk = AndroidRelease(
  nextVersion,
  Uri.parse(apkPath),
  payload.length,
  sha256.convert(payload).toString(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'only newer stable Android releases with an exact uploaded APK and digest are offered',
    () {
      final windows = {...apk.publishedRow, 'tag_name': 'windows-v9.2.0'};
      final preview = {...apk.publishedRow, 'prerelease': true};
      expect(
        AndroidRelease.newest([windows, preview, apk.publishedRow])?.digest,
        apk.digest,
      );
      expect(AndroidRelease.newest([windows, preview]), isNull);
      expect(
        AndroidRelease.newest([apk.publishedRow], current: apk.version),
        isNull,
      );
      final wrongHost = AndroidRelease(
        apk.version,
        Uri.parse('$apkPath?mirror=1'),
        apk.size,
        apk.digest,
      );
      expect(
        () => AndroidRelease.newest([wrongHost.publishedRow]),
        throwsA(isA<UpdateFailure>()),
      );
      final missingDigest = AndroidRelease(apk.version, apk.url, apk.size, '');
      expect(
        () => AndroidRelease.newest([missingDigest.publishedRow]),
        throwsA(isA<UpdateFailure>()),
      );
      expect(
        AndroidAppUpdate.assetHost(
          Uri.parse(
            'https://release-assets.githubusercontent.com.example.org/',
          ),
        ),
        isFalse,
      );
      expect(
        AndroidAppUpdate.assetHost(Uri.parse('https://github.com:9443/file')),
        isFalse,
      );
    },
  );

  group('update transfer', () {
    late Directory root;
    late List<(Uri, Map<String, String>)> requests;
    late _Response Function(Uri, Map<String, String>) respond;
    late AndroidAppUpdate updater;

    AndroidAppUpdate makeUpdater() => AndroidAppUpdate(
      retryDelays: const [Duration.zero, Duration.zero],
      createClient: () => _Client((url, headers) {
        requests.add((url, Map.of(headers)));
        if (url.host == 'api.github.com') {
          return _Response(200, utf8.encode(jsonEncode([apk.publishedRow])));
        }
        return respond(url, headers);
      }),
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('update248_');
      requests = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidAppUpdate.channel, (call) async {
            if (call.method == 'directory') return root.path;
            if (call.method == 'permission') return true;
            if (call.method == 'install') {
              expect(call.arguments, {
                'version': apk.version,
                'digest': apk.digest,
              });
              return null;
            }
            fail('unexpected native method ${call.method}');
          });
      updater = makeUpdater();
    });
    tearDown(() async {
      updater.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidAppUpdate.channel, null);
      await root.delete(recursive: true);
    });

    File file(String suffix) => File('${root.path}/${apk.digest}.$suffix');

    test(
      'saved metadata and a partial file survive relaunch; valid CDN range graduates to install',
      () async {
        await updater.check();
        await file('part').writeAsBytes(payload.take(2).toList());
        final relaunch = makeUpdater();
        addTearDown(relaunch.dispose);
        await relaunch.restore();
        expect(requests, hasLength(1));
        expect(relaunch.bytes, 2);
        respond = (url, headers) {
          expect(headers['range'], 'bytes=2-');
          if (url.host == 'github.com') {
            return _Response(302, [], {
              'location':
                  'https://release-assets.githubusercontent.com/download',
            });
          }
          return _Response(206, payload.skip(2).toList(), {
            'content-range': 'bytes 2-4/5',
          });
        };
        await relaunch.download();
        expect(relaunch.verified, isTrue);
        expect(file('apk').readAsBytesSync(), payload);
        expect(file('part').existsSync(), isFalse);
        await relaunch.install();
        expect(relaunch.message, '请在 Android 安装界面确认');
      },
    );

    test(
      'wrong content range restarts once without appending invalid bytes',
      () async {
        await updater.check();
        await file('part').writeAsBytes(payload.take(2).toList());
        respond = (_, headers) => headers['range'] == 'bytes=2-'
            ? _Response(206, [0, 0, 0], {'content-range': 'bytes 1-3/5'})
            : _Response(200, payload);
        await updater.download();
        expect(file('apk').readAsBytesSync(), payload);
        expect(requests.skip(1).map((entry) => entry.$2['range']), [
          'bytes=2-',
          null,
        ]);
      },
    );

    test(
      'expired CDN redirect retries the official URL and keeps the prefix',
      () async {
        await updater.check();
        await file('part').writeAsBytes(payload.take(2).toList());
        var official = 0;
        respond = (url, headers) {
          expect(headers['range'], 'bytes=2-');
          if (url.host == 'github.com') {
            return _Response(302, [], {
              'location':
                  'https://release-assets.githubusercontent.com/link/${++official}',
            });
          }
          return url.path.endsWith('/1')
              ? _Response(403, [])
              : _Response(206, payload.skip(2).toList(), {
                  'content-range': 'bytes 2-4/5',
                });
        };
        await updater.download();
        expect(official, 2);
        expect(file('apk').readAsBytesSync(), payload);
      },
    );

    test('429 reports rate limiting and retains the partial', () async {
      await updater.check();
      await file('part').writeAsBytes(payload.take(2).toList());
      respond = (_, _) => _Response(429, []);
      await updater.download();
      expect(updater.message, contains('限流'));
      expect(file('part').readAsBytesSync(), [1, 3]);
      expect(requests, hasLength(2));
    });

    test(
      'tampered bytes are discarded and a nonofficial redirect is never contacted',
      () async {
        await updater.check();
        respond = (_, _) =>
            _Response(302, [], {'location': 'https://example.org/download'});
        await updater.download();
        expect(requests.map((entry) => entry.$1.host), [
          'api.github.com',
          'github.com',
        ]);
        respond = (_, _) => _Response(200, [0, 0, 0, 0, 0]);
        await updater.download();
        expect(updater.verified, isFalse);
        expect(file('apk').existsSync(), isFalse);
        expect(file('part').existsSync(), isFalse);
        expect(updater.message, contains('SHA-256'));
      },
    );
  });

  test(
    'correction uses separate preferences and can be forgotten without touching other accounts or episodes',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final a = DanmakuCorrections.key('https://sample.invalid', 'a', '5');
      final b = DanmakuCorrections.key('https://sample.invalid', 'b', '5');
      final next = DanmakuCorrections.key('https://sample.invalid', 'a', '6');
      const first = 'https://www.bilibili.com/bangumi/play/ep9';
      const second = 'https://v.qq.com/x/page/abcdefghijk.html';
      final corrections = DanmakuCorrections(prefs);
      expect(await corrections.save(a, first), isTrue);
      expect(await corrections.save(b, second), isTrue);
      await prefs.reload();
      expect(DanmakuCorrections(prefs).lookup(a), first);
      expect(DanmakuCorrections(prefs).lookup(next), isNull);
      expect(await corrections.save(a, null), isTrue);
      expect(corrections.lookup(a), isNull);
      expect(corrections.lookup(b), second);
    },
  );

  test(
    'disabled sources issue no request and offsets are independently persisted',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var selected = const DanmakuPreferences().configure('腾讯视频', delay: 1.5);
      for (final source in danmakuSourceNames) {
        selected = selected.configure(source, enabled: false);
      }
      await selected.save(prefs);
      final settings = DanmakuPreferences.read(prefs);
      expect(settings.delays, {'腾讯视频': 1.5});
      expect(settings.hidden, danmakuSourceNames.toSet());
      final contacted = <Uri>[];
      final source = DanmakuSources(
        read: (uri) async {
          contacted.add(uri);
          return Uint8List.fromList(utf8.encode('{}'));
        },
      );
      addTearDown(source.close);
      const id = (
        title: '合成剧',
        season: 1,
        episode: 2,
        year: 0,
        seconds: 120,
        absolute: 0,
        continuous: false,
      );
      expect(await source.search(id, '剧名', hidden: settings.hidden), isEmpty);
      expect(
        await source.search(
          id,
          'https://v.qq.com/x/page/abcdefghijk.html',
          hidden: settings.hidden,
        ),
        isEmpty,
      );
      expect(contacted, isEmpty);
    },
  );

  test(
    'feedback freezes only recent playback rows, with logs and title excluded by default',
    () {
      final now = DateTime(2026, 11, 16, 12);
      LogEntry row(
        int minutes,
        String message, {
        LogArea area = LogArea.player,
        int code = androidVersionCode,
      }) => LogEntry(
        now.subtract(Duration(minutes: minutes)),
        appVersion,
        area,
        LogLevel.warning,
        message,
        buildCode: code,
      );
      final log = DiagnosticLog(
        restored: [
          row(12, 'outside-report-window'),
          row(5, 'previous-playback'),
          row(3, 'other-app-area', area: LogArea.api),
          row(2, 'older-build', code: androidVersionCode - 1),
          row(1, 'safe-line actual-local-credential'),
        ],
      );
      log.protect(['actual-local-credential']);
      final report = PlaybackReport(
        log: log,
        started: now.subtract(const Duration(minutes: 4)),
        title: 'PRIVATE_TITLE',
        position: Duration.zero,
        created: now,
      );
      final minimal = report.render(
        category: '播放异常',
        description: '起播异常',
        includeTitle: false,
        includeDiagnostics: false,
      );
      expect(minimal, contains('0.0 秒'));
      expect(minimal, isNot(contains('PRIVATE_TITLE')));
      expect(minimal, isNot(contains('safe-line')));
      final full = report.render(
        category: '播放异常',
        description: 'actual-local-credential',
        includeTitle: true,
        includeDiagnostics: true,
      );
      expect(report.diagnostics, hasLength(1));
      expect(full, contains('safe-line'));
      expect(full, contains('PRIVATE_TITLE'));
      expect(full, isNot(contains('actual-local-credential')));
      log.dispose();
    },
  );
}

class _Client implements HttpClient {
  _Client(this.respond);
  final _Response Function(Uri, Map<String, String>) respond;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _Request((headers) => respond(url, headers));
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.respond);
  final _Response Function(Map<String, String>) respond;
  @override
  bool followRedirects = false;
  @override
  final _Headers headers = _Headers({});
  @override
  Future<HttpClientResponse> close() async => respond(headers.values);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    this.statusCode,
    this.body, [
    Map<String, String> headers = const {},
  ]) : headers = _Headers(Map.of(headers));
  final List<int> body;
  @override
  final int statusCode;
  @override
  int get contentLength => body.length;
  @override
  final HttpHeaders headers;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(Uint8List.fromList(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  _Headers(this.values);
  final Map<String, String> values;
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
