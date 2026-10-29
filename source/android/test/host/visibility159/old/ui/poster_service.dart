import 'dart:async';
import 'dart:io' show HttpDate, HttpException;
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import '../core/models.dart';

/// Only current, visible image widgets register demand. Queued cache-manager
/// downloads recheck it immediately before sending an HTTP request.
class PosterDemand {
  static final _owners = <Object, String>{};
  static final _listeners = <String, Set<void Function()>>{};
  static final _pauses = <Object>{};
  static final loadingPaused = ValueNotifier(false);
  static Completer<void>? _resumed;
  static void pause(Object owner, bool paused) {
    paused ? _pauses.add(owner) : _pauses.remove(owner);
    final next = _pauses.isNotEmpty;
    if (next == loadingPaused.value) return;
    if (next) {
      _resumed = Completer<void>();
    } else {
      _resumed?.complete();
      _resumed = null;
    }
    loadingPaused.value = next;
    for (final callbacks in List.of(_listeners.values)) {
      for (final callback in List.of(callbacks)) {
        callback();
      }
    }
  }

  static Future<void> waitUntilResumed() async {
    while (_resumed != null) {
      await _resumed!.future;
    }
  }

  static void set(Object owner, String? url) {
    final previous = _owners[owner];
    if (previous == url) return;
    if (url == null) {
      _owners.remove(owner);
    } else {
      _owners[owner] = url;
    }
    for (final changed in {previous, url}.whereType<String>()) {
      for (final callback in List.of(
        _listeners[changed] ?? <void Function()>{},
      )) {
        callback();
      }
    }
  }

  static bool visible(String url) => _owners.containsValue(url);
  static void Function() listen(String url, void Function() callback) {
    (_listeners[url] ??= {}).add(callback);
    return () {
      _listeners[url]?.remove(callback);
      if (_listeners[url]?.isEmpty == true) _listeners.remove(url);
    };
  }
}

class PosterFileService extends FileService {
  PosterFileService({
    http.Client? client,
    DateTime Function()? now,
    this.spacing = const Duration(seconds: 1),
    this.requestLimit = 3,
    Future<void> Function(Duration)? delay,
    bool Function(String)? visible,
  }) : client = client ?? http.Client(),
       now = now ?? DateTime.now,
       delay = delay ?? Future<void>.delayed,
       visible = visible ?? PosterDemand.visible {
    concurrentFetches = 2;
  }
  final http.Client client;
  final DateTime Function() now;
  Duration spacing;
  int requestLimit;
  static const requestWindow = Duration(seconds: 1);
  final Future<void> Function(Duration) delay;
  final _starts = <DateTime>[];
  final bool Function(String) visible;
  DateTime? _lastStarted;
  final _cooldown = <String, DateTime>{};
  final _failures = <String, int>{};
  Future<void> _tail = Future<void>.value();
  final _slots = <Completer<void>>[];
  int _active = 0;
  @override
  Future<FileServiceResponse> get(
    String url, {
    Map<String, String>? headers,
  }) async {
    // One global cap shared by posters and backdrops, including response bodies.
    if (_active >= 2) {
      final slot = Completer<void>();
      _slots.add(slot);
      await slot.future;
    } else {
      _active++;
    }
    try {
      return await _download(url, headers: headers);
    } finally {
      if (_slots.isEmpty) {
        _active--;
      } else {
        _slots.removeAt(0).complete();
      }
    }
  }

  void _check(String url) {
    final uri = Uri.parse(url);
    if (PosterDemand.loadingPaused.value) throw const AppFailure('图片加载已暂停');
    if (!visible(url)) throw const AppFailure('图片已离开当前页面');
    if (_cooldown[uri.origin]?.isAfter(now()) == true) {
      throw const AppFailure('图片加载暂缓，等待服务器恢复');
    }
  }

  Future<void> _admit(String url) async {
    while (true) {
      await PosterDemand.waitUntilResumed();
      _check(url);
      final at = now();
      _starts.removeWhere((value) => at.difference(value) >= requestWindow);
      var wait = _lastStarted == null
          ? Duration.zero
          : spacing - at.difference(_lastStarted!);
      final limit = requestLimit.clamp(1, 3);
      if (requestLimit != 0 && _starts.length >= limit) {
        final budgetWait = _starts[_starts.length - limit]
            .add(requestWindow)
            .difference(at);
        if (budgetWait > wait) wait = budgetWait;
      }
      if (wait <= Duration.zero) break;
      // Recheck pause, visibility, the current speed and rolling budget after
      // every wait. Attempts count even when cancelled or rejected by server.
      await delay(wait);
    }
    _check(url);
    _lastStarted = now();
    _starts.add(_lastStarted!);
    // Only the three most recent starts are needed when returning to a quota.
    if (_starts.length > 3) _starts.removeAt(0);
  }

  Future<FileServiceResponse> _download(
    String url, {
    Map<String, String>? headers,
  }) async {
    // Reserve start times serially, while allowing up to two bodies in flight.
    final admission = _tail.then((_) => _admit(url));
    _tail = admission.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    await admission;
    _check(url);
    final uri = Uri.parse(url);
    final abort = Completer<void>();
    Timer? hiddenDelay;
    var offscreen = false;
    final unsubscribe = PosterDemand.listen(url, () {
      hiddenDelay?.cancel();
      if (PosterDemand.loadingPaused.value) {
        offscreen = true;
        if (!abort.isCompleted) abort.complete();
      } else if (!visible(url)) {
        hiddenDelay = Timer(const Duration(milliseconds: 120), () {
          if (!visible(url) && !abort.isCompleted) {
            offscreen = true;
            abort.complete();
          }
        });
      }
    });
    try {
      final request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: abort.future,
      );
      if (headers != null) request.headers.addAll(headers);
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 12));
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 12),
      )) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          throw const AppFailure('图片文件过大');
        }
        bytes.addAll(chunk);
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        final seconds = retryAfterSeconds(response.headers['retry-after']);
        coolDown(uri.origin, seconds: seconds);
      } else if (response.statusCode == 200 || response.statusCode == 304) {
        _failures.remove(uri.origin);
      }
      return _PosterResponse(
        HttpGetResponse(
          http.StreamedResponse(
            Stream.value(bytes),
            response.statusCode,
            headers: response.headers,
            contentLength: bytes.length,
          ),
        ),
        uri.queryParameters['tag']?.isNotEmpty == true,
        now(),
      );
    } catch (_) {
      // Scrolling cancellation is expected, not evidence of a failing server.
      if (!offscreen) coolDown(uri.origin);
      rethrow;
    } finally {
      hiddenDelay?.cancel();
      unsubscribe();
      // Also abort a headers timeout; the underlying connection must not keep
      // running while the cache manager begins the next queued image.
      if (!abort.isCompleted) abort.complete();
    }
  }

  int? retryAfterSeconds(String? value) {
    if (value == null) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return seconds >= 0 ? seconds : null;
    try {
      final wait = HttpDate.parse(value).difference(now());
      return wait.isNegative ? null : (wait.inMilliseconds / 1000).ceil();
    } on HttpException {
      return null;
    }
  }

  void coolDown(String origin, {int? seconds}) {
    final count = ((_failures[origin] ?? 0) + 1).clamp(1, 4);
    _failures[origin] = count;
    final delay = seconds ?? 30 * (1 << (count - 1));
    final until = now().add(Duration(seconds: delay < 30 ? 30 : delay));
    // Honor a longer server-requested wait, including Retry-After dates.
    if (_cooldown[origin]?.isAfter(until) != true) _cooldown[origin] = until;
  }
}

class _PosterResponse implements FileServiceResponse {
  _PosterResponse(this.source, this.versioned, this.at);
  final FileServiceResponse source;
  final bool versioned;
  final DateTime at;
  @override
  Stream<List<int>> get content => source.content;
  @override
  int? get contentLength => source.contentLength;
  @override
  int get statusCode => source.statusCode;
  @override
  String? get eTag => source.eTag;
  @override
  String get fileExtension => source.fileExtension;
  // The server's image tag is part of the key. A new tag gets a new image.
  @override
  DateTime get validTill =>
      versioned ? at.add(const Duration(days: 36500)) : source.validTill;
}
