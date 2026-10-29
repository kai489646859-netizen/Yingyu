import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_cache.dart';
import 'package:yingyu/playback/disc_transport.dart' as production;

import 'disc_test.dart' show route;
import 'host/player101/current_disc.dart' as current;
import 'host/player101/old_disc.dart' as old;

// Virtual time exercises the complete public native-input path, including
// identity/range validation, request ownership, timeout and cancellation.
class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = '$value';
  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, int start, {String? location})
    : super(
        Stream<List<int>>.fromIterable([
          Uint8List.fromList([1, 2, 3, 4]),
        ]),
      ) {
    headers.set('content-range', 'bytes $start-${start + 3}/100');
    if (location != null) headers.set('location', location);
  }
  @override
  final int statusCode;
  @override
  final headers = _Headers();
  @override
  int get contentLength => 4;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _Subscription(
    super.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// SDK streams can return a cached root-zone cancel future. Keep completion in
// this synthetic clock's zone rather than waiting for a real event-loop turn.
class _Subscription implements StreamSubscription<List<int>> {
  _Subscription(this.inner);
  final StreamSubscription<List<int>> inner;
  @override
  Future<void> cancel() {
    unawaited(inner.cancel());
    return Future<void>.value();
  }

  @override
  void onData(void Function(List<int>)? value) => inner.onData(value);
  @override
  void onError(Function? value) => inner.onError(value);
  @override
  void onDone(void Function()? value) => inner.onDone(value);
  @override
  void pause([Future<void>? signal]) => inner.pause(signal);
  @override
  void resume() => inner.resume();
  @override
  bool get isPaused => inner.isPaused;
  @override
  Future<E> asFuture<E>([E? value]) => inner.asFuture<E>(value);
}

class _Request implements HttpClientRequest {
  _Request(this.owner, this.uri, this.delay, this.status);
  final _Client owner;
  @override
  final Uri uri;
  final Duration delay;
  final int status;
  Timer? timer;
  Completer<HttpClientResponse>? pending;
  @override
  final headers = _Headers();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() {
    final result = pending = Completer<HttpClientResponse>();
    timer = Timer(delay, () {
      if (!result.isCompleted) {
        final start = int.parse(
          headers.value('range')!.split('=')[1].split('-')[0],
        );
        result.complete(
          _Response(
            status,
            start,
            location: status == 302
                ? 'http://media.invalid/resolved.iso'
                : null,
          ),
        );
      }
    });
    return result.future;
  }

  void abortPending() {
    timer?.cancel();
    if (pending case final result? when !result.isCompleted) {
      result.completeError(const SocketException('synthetic client closed'));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements HttpClient {
  _Client(this.script);
  final _Script script;
  final requests = <_Request>[];
  @override
  Future<HttpClientRequest> getUrl(Uri uri) async {
    final at = script.requests.length;
    final request = _Request(this, uri, script.delays[at], script.statuses[at]);
    requests.add(request);
    script.requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    script.closes++;
    for (final request in requests) {
      request.abortPending();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isSetter) return null;
    return super.noSuchMethod(invocation);
  }
}

class _Script extends HttpOverrides {
  _Script(this.delays, {List<int>? statuses})
    : statuses = statuses ?? List.filled(delays.length, 206);
  final List<Duration> delays;
  final List<int> statuses;
  final requests = <_Request>[];
  int closes = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(this);
}

void main() {
  void advance(FakeAsync time, Duration duration) {
    time.flushMicrotasks();
    time.elapse(duration);
    time.flushMicrotasks();
  }

  dynamic transport() =>
      current.DiscHeaderProbe(route('http://media.invalid/film.iso'));
  test(
    'public native input returns exact bytes after a timely first header',
    () {
      fakeAsync((time) {
        final script = _Script([const Duration(seconds: 5)]);
        HttpOverrides.runWithHttpOverrides(() {
          final disc = production.DiscTransport(
            route('http://media.invalid/film.iso'),
            kind: DiscKind.iso,
            nativeInvoke: (_, _) async => null,
          );
          DiscRangeBlock? result;
          Object? error;
          unawaited(
            disc
                .readNativeInput(1, '', 0, 4, DiscReadCancellation())
                .then(
                  (v) {
                    result = v;
                  },
                  onError: (Object e) {
                    error = e;
                  },
                ),
          );
          advance(time, const Duration(seconds: 5));
          expect(error, isNull);
          expect(result?.bytes, [1, 2, 3, 4]);
          expect(script.requests, hasLength(1));
          unawaited(disc.close());
          advance(time, Duration.zero);
        }, script);
      });
    },
  );
  test(
    'complete 1.0.0 owner rejects the same first response at 30 seconds',
    () {
      fakeAsync((time) {
        final script = _Script([const Duration(seconds: 35)]);
        HttpOverrides.runWithHttpOverrides(() {
          final disc = old.DiscHeaderProbe(
            route('http://media.invalid/film.iso'),
          );
          Object? error;
          unawaited(
            disc
                .headerProbe(DiscReadCancellation())
                .then(
                  (_) {},
                  onError: (Object e) {
                    error = e;
                  },
                ),
          );
          advance(time, const Duration(seconds: 30));
          expect('$error', contains('30 秒'));
          expect(script.requests, hasLength(1));
          disc.closeProbe();
          advance(time, Duration.zero);
        }, script);
      });
    },
  );
  for (final delay in [Duration.zero, const Duration(seconds: 5)]) {
    test('first disc response at $delay succeeds with exactly one GET', () {
      fakeAsync((time) {
        final script = _Script([delay]);
        HttpOverrides.runWithHttpOverrides(() {
          final disc = transport();
          Object? error;
          int? value;
          unawaited(
            disc
                .headerProbe(DiscReadCancellation())
                .then(
                  (v) {
                    value = v;
                  },
                  onError: (Object e) {
                    error = e;
                  },
                ),
          );
          advance(time, Duration.zero);
          advance(time, delay);
          expect(error, isNull);
          expect(value, 206);
          expect(script.requests, hasLength(1));
          disc.closeProbe();
          advance(time, Duration.zero);
        }, script);
      });
    });
  }
  test('later response retains 30-second timeout and failure latch', () {
    fakeAsync((time) {
      final script = _Script([Duration.zero, const Duration(seconds: 35)]);
      HttpOverrides.runWithHttpOverrides(() {
        final disc = transport();
        var firstDone = false;
        unawaited(
          disc.headerProbe(DiscReadCancellation()).then((_) {
            firstDone = true;
          }),
        );
        advance(time, Duration.zero);
        expect(firstDone, true);
        Object? error;
        unawaited(
          disc
              .headerProbe(DiscReadCancellation())
              .then(
                (_) {},
                onError: (Object e) {
                  error = e;
                },
              ),
        );
        advance(time, const Duration(seconds: 30));
        expect('$error', contains('30 秒'));
        expect(
          disc.headerProbe(DiscReadCancellation()),
          throwsA(isA<AppFailure>()),
        );
        advance(time, Duration.zero);
        expect(script.requests, hasLength(2));
        disc.closeProbe();
        advance(time, Duration.zero);
      }, script);
    });
  });
  for (final cancel in [false, true]) {
    test('first response has finite budget, cancellation=$cancel', () {
      fakeAsync((time) {
        final script = _Script([const Duration(seconds: 90)]);
        HttpOverrides.runWithHttpOverrides(() {
          final disc = transport();
          final token = DiscReadCancellation();
          Object? error;
          unawaited(
            disc
                .headerProbe(token)
                .then(
                  (_) {},
                  onError: (Object e) {
                    error = e;
                  },
                ),
          );
          advance(time, Duration.zero);
          if (cancel) {
            advance(time, const Duration(seconds: 2));
            token.cancel();
            advance(time, Duration.zero);
            expect(disc.failure, isNull);
          } else {
            advance(time, const Duration(seconds: 30));
            expect('$error', contains('30 秒'));
          }
          expect(error, isNotNull);
          expect(script.requests, hasLength(1));
          expect(script.closes, greaterThan(0));
          disc.closeProbe();
          advance(time, Duration.zero);
        }, script);
      });
    });
  }
  test(
    'redirect target keeps ordinary timeout and never revisits the entry',
    () {
      fakeAsync((time) {
        final script = _Script(
          [Duration.zero, const Duration(seconds: 35)],
          statuses: [302, 206],
        );
        HttpOverrides.runWithHttpOverrides(() {
          final disc = transport();
          Object? error;
          unawaited(
            disc
                .headerProbe(DiscReadCancellation())
                .then(
                  (_) {},
                  onError: (Object e) {
                    error = e;
                  },
                ),
          );
          advance(time, Duration.zero);
          advance(time, const Duration(seconds: 30));
          expect('$error', contains('30 秒'));
          expect(script.requests.map((r) => r.uri.path), [
            '/film.iso',
            '/resolved.iso',
          ]);
          disc.closeProbe();
          advance(time, Duration.zero);
        }, script);
      });
    },
  );
}
