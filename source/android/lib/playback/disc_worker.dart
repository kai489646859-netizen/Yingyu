import 'dart:async';
import 'dart:isolate';
import '../core/log.dart';
import '../core/models.dart';
import 'disc_transport.dart';
import 'disc_native.dart';

/// One long-lived IO isolate per temporary disc session. Only native control,
/// redacted logs and bounded status snapshots cross the UI isolate. HTTP media
/// bodies, range caches and the Java input server stay together in the worker.
/// Persistent video-cache sessions keep their existing shared cache owner.
class DiscWorkerTransport extends DiscTransport {
  DiscWorkerTransport(
    super.route, {
    required super.kind,
    super.log,
    super.onStage,
    super.address,
    super.onFailure,
    super.cacheBytes,
    super.nativeInvoke,
    this.directNative = false,
    this.nativeLibraryPath,
  }) : super(backgroundOutput: true);
  final bool directNative;
  final String? nativeLibraryPath;

  ReceivePort? _events;
  Isolate? _isolate;
  SendPort? _commands;
  final _connected = Completer<void>();
  final _started = Completer<String>();
  final _ended = Completer<void>();
  bool _launched = false, _closing = false;
  double _requestedSpeed = 1;
  String _health = '原盘独立读取线程正在准备';
  Future<void>? _closeJob;
  Future<void>? _healthJob;
  final _healthClock = Stopwatch()..start();

  @override
  String get readHealth =>
      '读取线程快照距今=${_healthClock.elapsedMilliseconds} ms；$_health';

  @override
  Future<void> refreshReadHealth() {
    if (_closing || _commands == null) return Future.value();
    return _healthJob ??= _refreshReadHealth();
  }

  Future<void> _refreshReadHealth() async {
    final reply = ReceivePort();
    try {
      _commands!.send(['status', reply.sendPort]);
      final value = await reply.first.timeout(const Duration(seconds: 2));
      if (!_closing) {
        _health = value as String;
        _healthClock.reset();
      }
    } catch (_) {
      /* A stale diagnostic snapshot must not stop media IO. */
    } finally {
      reply.close();
      _healthJob = null;
    }
  }

  @override
  Future<String> start({int? playlist}) async {
    if (_closing) throw const AppFailure('播放已退出');
    if (_launched) return _started.future;
    _launched = true;
    // Attach handlers before spawning: even a very early worker failure must
    // settle opening/closing rather than leaving a pending session behind.
    unawaited(_started.future.catchError((Object _) => ''));
    unawaited(_connected.future.catchError((Object _) {}));
    _events = ReceivePort()..listen(_receive);
    try {
      _isolate = await Isolate.spawn(
        _discWorkerMain,
        _WorkerStart(
          _events!.sendPort,
          route,
          kind,
          address,
          cacheBytes,
          id,
          playlist,
          directNative,
          nativeLibraryPath,
        ),
        onError: _events!.sendPort,
        onExit: _events!.sendPort,
        errorsAreFatal: true,
        debugName: 'yingyu-disc-io',
      );
      return await _started.future;
    } catch (_) {
      _fail('原盘独立读取线程未能启动');
      await close();
      rethrow;
    }
  }

  void _fail(String message) {
    final error = AppFailure(message);
    if (!_connected.isCompleted) _connected.completeError(error);
    if (!_started.isCompleted) _started.completeError(error);
    if (!_closing && failure == null) {
      failure = message;
      onFailure?.call(message);
    }
  }

  void _receive(dynamic message) {
    if (message == null) {
      if (!_ended.isCompleted) _ended.complete();
      if (!_closing) {
        _fail('原盘独立读取线程意外结束，请重试');
        unawaited(close());
      }
      return;
    }
    if (message is! List || message.isEmpty) return;
    switch (message[0]) {
      case 'connected':
        _commands = message[1] as SendPort;
        if (!_connected.isCompleted) _connected.complete();
        _commands!.send(['speed', _requestedSpeed]);
      case 'native':
        unawaited(_nativeControl(message));
      case 'ready':
        if (_closing) return;
        titles = (message[2] as List).cast<DiscTitle>();
        selected = titles.firstWhere((t) => t.playlist == message[3]);
        base = message[4] as String;
        _health = message[5] as String;
        route.playMethod = message[6] as String;
        seekIndex = message.length > 7 ? message[7] as String : '';
        _healthClock.reset();
        if (!_started.isCompleted) _started.complete(message[1] as String);
      case 'status':
        if (!_closing) {
          _health = message[1] as String;
          _healthClock.reset();
        }
      case 'stage':
        if (!_closing) onStage?.call(message[1] as String);
      case 'log':
        if (!_closing) {
          log?.add(
            message[1] as LogArea,
            '${message[3]}；读取线程日志延迟=${DateTime.now().millisecondsSinceEpoch - (message[4] as int)} ms',
            level: message[2] as LogLevel,
          );
        }
      case 'failed':
        _fail(message[1] as String);
      default:
        // Isolate error messages can contain implementation details/addresses.
        // Never retain the raw exception or stack in the user diagnostic log.
        _fail('原盘独立读取线程发生异常，请重试');
        unawaited(close());
    }
  }

  Future<void> _nativeControl(List message) async {
    final reply = message[1] as SendPort;
    final method = message[2] as String;
    // A programming mistake must not turn this control channel back into the
    // video-byte path. Close remains available after UI cancellation.
    if (!const {'open', 'output', 'outputStatus', 'close'}.contains(method) ||
        (_closing && method != 'close')) {
      reply.send([false, '原盘控制操作已取消']);
      return;
    }
    try {
      final args = (message[3] as Map).cast<String, Object?>();
      final value = nativeInvoke != null
          ? await nativeInvoke!(method, args)
          : await DiscTransport.channel.invokeMethod<Object?>(method, args);
      reply.send([true, value]);
    } catch (error) {
      reply.send([
        false,
        redactLog(safeError(error), secrets: route.diagnosticSecrets),
      ]);
    }
  }

  @override
  void setBuffering(bool value) {
    if (!_closing) _commands?.send(['buffering', value]);
  }

  @override
  void setSpeed(double speed) {
    if (_closing || !speed.isFinite || speed < .5 || speed > 3) return;
    _requestedSpeed = speed;
    _commands?.send(['speed', speed]);
  }

  @override
  void resetReadAhead() {
    if (!_closing) _commands?.send(['seek']);
  }

  @override
  Future<void> close() => _closeJob ??= _close();

  Future<void> _close() async {
    _closing = true;
    if (!_started.isCompleted && _launched) {
      _started.completeError(const AppFailure('播放已退出'));
    }
    if (!_launched) return;
    try {
      await _connected.future.timeout(const Duration(seconds: 3));
      _commands?.send(['close']);
      await _ended.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      // The native session has an independent cancellation path even when the
      // worker failed or did not acknowledge shutdown. Use the same session ID.
      try {
        if (directNative) {
          DiscNativeApi(libraryPath: nativeLibraryPath).cancel(id);
        } else {
          final args = <String, Object?>{'id': id};
          await (nativeInvoke != null
                  ? nativeInvoke!('close', args)
                  : DiscTransport.channel.invokeMethod<Object?>('close', args))
              .timeout(const Duration(seconds: 3));
        }
      } catch (_) {
        /* native close is already best-effort in DiscTransport */
      }
    } finally {
      _isolate?.kill(priority: Isolate.immediate);
      _events?.close();
    }
  }
}

class _WorkerStart {
  const _WorkerStart(
    this.parent,
    this.route,
    this.kind,
    this.address,
    this.cacheBytes,
    this.id,
    this.playlist,
    this.directNative,
    this.nativeLibraryPath,
  );
  final SendPort parent;
  final PlaybackRoute route;
  final DiscKind kind;
  final String? address;
  final int cacheBytes;
  final String id;
  final int? playlist;
  final bool directNative;
  final String? nativeLibraryPath;
}

class _WorkerLog extends DiagnosticLog {
  _WorkerLog(this.parent, Iterable<String> secrets) {
    protect(secrets);
  }
  final SendPort parent;
  @override
  String nextRequest(String prefix) => super.nextRequest('$prefix后台');
  @override
  void add(LogArea area, String message, {LogLevel level = LogLevel.info}) {
    parent.send([
      'log',
      area,
      level,
      sanitize(message),
      DateTime.now().millisecondsSinceEpoch,
    ]);
  }
}

Future<void> _discWorkerMain(_WorkerStart args) async {
  final commands = ReceivePort();
  final log = _WorkerLog(args.parent, args.route.diagnosticSecrets);
  final nativeReplies = <ReceivePort>{};
  var closing = false;
  late final DiscTransport transport;
  final direct = args.directNative
      ? DiscNativeSession(
          args.id,
          (op, path, offset, length, cancellation) =>
              transport.readNativeInput(op, path, offset, length, cancellation),
          libraryPath: args.nativeLibraryPath,
        )
      : null;
  Future<Object?> native(String method, Map<String, Object?> values) async {
    if (direct != null) return direct.invoke(method, values);
    final reply = ReceivePort();
    nativeReplies.add(reply);
    try {
      args.parent.send(['native', reply.sendPort, method, values]);
      final response = await reply.first as List;
      if (response[0] != true) throw AppFailure(response[1] as String);
      return response[1];
    } finally {
      nativeReplies.remove(reply);
      reply.close();
    }
  }

  transport = DiscTransport(
    args.route,
    kind: args.kind,
    address: args.address,
    cacheBytes: args.cacheBytes,
    sessionId: args.id,
    backgroundOutput: !args.directNative,
    directInput: args.directNative,
    nativeInvoke: native,
    log: log,
    onStage: (stage) => args.parent.send(['stage', stage]),
    onFailure: (error) => args.parent.send(['failed', error]),
  );
  String health() => '原盘数据线程=独立；${direct?.health ?? ''}${transport.readHealth}';
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    if (!closing) args.parent.send(['status', health()]);
  });
  Future<void> close() async {
    if (closing) return;
    closing = true;
    timer.cancel();
    try {
      await transport.close();
    } finally {
      commands.close();
      for (final port in nativeReplies.toList()) {
        port.close();
      }
      log.dispose();
      Isolate.exit();
    }
  }

  commands.listen((dynamic message) {
    if (message is! List || closing) return;
    switch (message[0]) {
      case 'speed':
        transport.setSpeed(message[1] as double);
      case 'buffering':
        transport.setBuffering(message[1] == true);
      case 'seek':
        transport.resetReadAhead();
      case 'status':
        (message[1] as SendPort).send(health());
      case 'close':
        unawaited(close());
    }
  });
  args.parent.send(['connected', commands.sendPort]);
  try {
    final address = await transport.start(playlist: args.playlist);
    if (!closing) {
      args.parent.send([
        'ready',
        address,
        transport.titles,
        transport.selected!.playlist,
        transport.base,
        health(),
        args.route.playMethod,
        transport.seekIndex,
      ]);
    }
  } catch (error) {
    if (!closing) {
      args.parent.send([
        'failed',
        redactLog(safeError(error), secrets: args.route.diagnosticSecrets),
      ]);
      await close();
    }
  }
}
