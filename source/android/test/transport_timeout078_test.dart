import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/origin_transport.dart';
import 'package:yingyu/playback/disc_transport.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'origin_transport_test.dart' show route;

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value is Iterable ? value.join(',') : '$value';
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  List<String>? operator [](String name) =>
      values.containsKey(name.toLowerCase()) ? [value(name)!] : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request([this.response]);
  final HttpClientResponse? response;
  @override
  final HttpHeaders headers = _Headers();
  @override
  bool followRedirects = false;
  @override
  Future<HttpClientResponse> close() async =>
      response ?? (throw TimeoutException('synthetic headers'));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.fail);
  final bool fail;
  @override
  final HttpHeaders headers = _Headers();
  @override
  int get statusCode => 200;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      (fail
              ? Stream<List<int>>.error(TimeoutException('synthetic body'))
              : Stream<List<int>>.value([1, 2, 3]))
          .listen(
            onData,
            onError: onError,
            onDone: onDone,
            cancelOnError: cancelOnError,
          );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.real, this.owner);
  final HttpClient real;
  final _Overrides owner;
  @override
  bool autoUncompress = false;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (url.host != 'timeout.invalid') return real.openUrl(method, url);
    owner.calls++;
    if (owner.body) return _Request(_Response(owner.calls == 1));
    if (!owner.headers) throw TimeoutException('synthetic connection');
    return _Request();
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  void close({bool force = false}) => real.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Overrides extends HttpOverrides {
  _Overrides(this.headers, {this.body = false});
  final bool headers;
  final bool body;
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(
    super.createHttpClient(context)..findProxy = (_) => 'DIRECT',
    this,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('body timeout retains resolved-target range recovery', () async {
    final overrides = _Overrides(true, body: true);
    await HttpOverrides.runWithHttpOverrides(() async {
      final transport = EmbyOriginTransport(route('https://timeout.invalid'));
      final client = HttpClient();
      try {
        final address = Uri.parse(await transport.start());
        await expectLater(() async {
          final first = await (await client.getUrl(address)).close();
          await first.drain<void>();
        }, throwsA(isA<HttpException>()));
        expect(transport.localFailure, contains('转发响应正文'));
        final next = await (await client.getUrl(address)).close();
        expect(next.statusCode, 200);
        expect(await next.fold<List<int>>([], (a, b) => a..addAll(b)), [
          1,
          2,
          3,
        ]);
        expect(overrides.calls, 2);
        expect(transport.localFailure, isNull);
      } finally {
        client.close(force: true);
        await transport.close();
      }
    }, overrides);
  });
  for (final headers in [false, true]) {
    final stage = headers ? '等待响应头' : '建立';
    test(
      'origin timeout $stage is local 504 and does not resolve again',
      () async {
        final overrides = _Overrides(headers);
        await HttpOverrides.runWithHttpOverrides(() async {
          final log = DiagnosticLog();
          final transport = EmbyOriginTransport(
            route('https://timeout.invalid'),
            log: log,
          );
          final client = HttpClient();
          try {
            final address = Uri.parse(await transport.start());
            for (var i = 0; i < 2; i++) {
              final result = await (await client.getUrl(address)).close();
              expect(result.statusCode, 504);
              await result.drain<void>();
            }
            expect(transport.localFailure, contains(stage));
            expect(transport.localFailure, contains('尚未收到上游 HTTP 响应'));
            expect(transport.localFailure, contains('0 字节'));
            expect(overrides.calls, 1);
            expect(log.export(), contains('不是上游响应状态'));
            expect(log.export(), isNot(contains('SYNTHETIC_TOKEN')));
          } finally {
            client.close(force: true);
            await transport.close();
          }
        }, overrides);
      },
    );
    test(
      'disc timeout $stage preserves the failed phase without retry',
      () async {
        final overrides = _Overrides(headers);
        await HttpOverrides.runWithHttpOverrides(() async {
          final transport = DiscTransport(
            route('https://timeout.invalid'),
            kind: DiscKind.iso,
            directInput: true,
            nativeInvoke: (_, _) async => null,
          );
          try {
            await expectLater(
              transport.readNativeInput(1, '', 0, 4096, DiscReadCancellation()),
              throwsA(
                isA<AppFailure>().having(
                  (e) => e.message,
                  'phase',
                  contains(stage),
                ),
              ),
            );
            expect(overrides.calls, 1);
          } finally {
            await transport.close();
          }
        }, overrides);
      },
    );
  }
}
