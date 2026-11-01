// ignore_for_file: unused_element, unused_element_parameter, unused_field, unused_import, prefer_final_fields, library_private_types_in_public_api
// Complete worker body with native/media/port IO substituted for timer replay.
import 'dart:async';

class SendPort {
  final sent = <dynamic>[];
  void send(dynamic value) => sent.add(value);
}
class ReceivePort {
  ReceivePort() { all.add(this); }
  static final all = <ReceivePort>[];
  final sendPort = SendPort();
  void Function(dynamic)? handler;
  bool closed = false;
  void listen(void Function(dynamic) value) { handler = value; }
  void deliver(dynamic value) { if (!closed) handler!(value); }
  Future<dynamic> get first => Completer<dynamic>().future;
  void close() { closed = true; }
}
class Isolate { static void exit() {} }
class AppFailure implements Exception { AppFailure(String text); }
String safeError(Object e) => 'synthetic';
String redactLog(String e, {Iterable<String> secrets = const []}) => e;
class _Route { final diagnosticSecrets = <String>[]; String playMethod='DirectPlay'; }
class _Selected { int playlist=1; }
class _WorkerLog { _WorkerLog(Object parent, Iterable<String> secrets) { latest=this; } static late _WorkerLog latest; bool enabled=true; void dispose() {} }
class DiscNativeSession {
  DiscNativeSession(Object id, dynamic read, {String? libraryPath});
  Future<Object?> invoke(String method, Map<String,Object?> values) async => null;
  String get health => 'synthetic native counters';
}
class DiscTransport {
  DiscTransport(Object route, {Object? kind, String? address, int? cacheBytes,
    String? sessionId, bool? backgroundOutput, bool? directInput,
    dynamic nativeInvoke, Object? log, required this.onStage, required this.onFailure}) { latest=this; }
  static late DiscTransport latest;
  final void Function(String) onStage, onFailure;
  int reads=0, counter=0, closes=0, seeks=0;
  final rates=<double>[], buffering=<bool>[];
  final titles=<Object>[];
  _Selected? selected=_Selected();
  String seekIndex=''; String base='synthetic';
  String get readHealth { reads++; return 'counter=$counter'; }
  Future<String> start({int? playlist}) async => 'synthetic';
  Future<void> close() async { closes++; }
  Object? readNativeInput(dynamic a,dynamic b,dynamic c,dynamic d,dynamic e) => null;
  void setSpeed(double value) { rates.add(value); }
  void setBuffering(bool value) { buffering.add(value); }
  void resetReadAhead() { seeks++; }
}
class _WorkerStart {
  final parent=SendPort(); final route=_Route(); final kind='iso';
  final String? address=null,nativeLibraryPath=null;
  final cacheBytes=1024; final id='synthetic'; final int? playlist=null;
  final directNative=false;
  bool logEnabled=true;
}
class WorkerHarness {
  final args=_WorkerStart();
  set initialLogging(bool value) { args.logEnabled=value; }
  bool get logging => _WorkerLog.latest.enabled;
  late ReceivePort commands;
  DiscTransport get transport => DiscTransport.latest;
  List<dynamic> get events => args.parent.sent;
  Future<void> start() async {
    final n=ReceivePort.all.length;
    await _discWorkerMain(args);
    commands=ReceivePort.all[n];
  }
  void command(List<dynamic> value) => commands.deliver(value);
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

