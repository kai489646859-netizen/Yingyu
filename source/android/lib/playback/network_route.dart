import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';

/// Opaque default-route generations; never Wi-Fi names, addresses or SIM data.
class PlaybackNetworkRoutes {
  static final shared = PlaybackNetworkRoutes();
  static const channel = EventChannel('yingyu/playback-network');
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  int revision = 0;
  String kind = 'unknown';
  bool available = false, known = false;
  int? _nativeRoute;
  void beginObservation() {
    known = false;
    available = false;
    kind = 'unknown';
    _nativeRoute = null;
  }

  Future<void> waitAvailable(Future<void> cancelled) async {
    if (!known || available) return;
    final ready = Completer<void>();
    final subscription = changes.listen((_) {
      if (available && !ready.isCompleted) ready.complete();
    });
    try {
      await Future.any([
        ready.future,
        cancelled,
      ]).timeout(const Duration(seconds: 8));
    } finally {
      await subscription.cancel();
    }
  }

  bool update(dynamic event) {
    if (event is! Map ||
        event['route'] is! int ||
        event['available'] is! bool) {
      return false;
    }
    final route = event['route'] as int;
    final online = event['available'] == true;
    final nextKind = switch (event['kind']) {
      'mobile' => 'mobile',
      'wifi' => 'wifi',
      'metered' => 'metered',
      'other' => 'other',
      _ => 'unknown',
    };
    if (known &&
        route == _nativeRoute &&
        online == available &&
        nextKind == kind) {
      return false;
    }
    final changed = known && (route != _nativeRoute || online != available);
    _nativeRoute = route;
    known = true;
    available = online;
    kind = nextKind;
    if (changed) revision++;
    _changes.add(null);
    return changed;
  }
}

class NetworkHandoff extends SocketException {
  const NetworkHandoff()
    : super('Default network changed during a stalled read');
}

/// Only a pending body read on an obsolete route gets a short deadline.
/// Healthy packets cancel it; there is no polling or action on a paused stream.
class NetworkReadGate {
  NetworkReadGate(this.routes, {this.grace = const Duration(seconds: 2)}) {
    _subscription = routes.changes.listen((_) => _arm());
  }
  final PlaybackNetworkRoutes routes;
  final Duration grace;
  late final StreamSubscription<void> _subscription;
  Timer? _timer;
  Completer<bool>? _pending;
  int _sourceRevision = 0;
  bool _eligible = false, _closed = false;
  void _arm() {
    if (_closed ||
        _pending == null ||
        !_eligible ||
        !routes.available ||
        routes.revision == _sourceRevision ||
        _timer != null) {
      return;
    }
    final pending = _pending!;
    _timer = Timer(grace, () {
      _timer = null;
      if (identical(_pending, pending) &&
          !pending.isCompleted &&
          routes.available &&
          routes.revision != _sourceRevision) {
        pending.completeError(const NetworkHandoff());
      }
    });
  }

  Future<bool> next(
    Future<bool> read, {
    required int revision,
    required bool eligible,
  }) async {
    final pending = Completer<bool>();
    _pending = pending;
    _sourceRevision = revision;
    _eligible = eligible;
    read.then(
      (value) {
        if (!pending.isCompleted) pending.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!pending.isCompleted) pending.completeError(error, stack);
      },
    );
    _arm();
    try {
      return await pending.future;
    } finally {
      if (identical(_pending, pending)) _pending = null;
      _timer?.cancel();
      _timer = null;
    }
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    unawaited(_subscription.cancel());
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(false);
  }
}
