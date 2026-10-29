import 'dart:async';
import 'device.dart';

/// One player route owns the window flag. Repeated clock events reuse the
/// successful/in-flight request; failed writes may be retried on the next event.
class PlayerAwake {
  PlayerAwake({Future<void> Function(bool)? write})
    : _write = write ?? Device.awake;
  final Future<void> Function(bool) _write;
  Future<void> _tail = Future.value(), _last = Future.value();
  bool? _wanted;
  bool _closed = false;
  int _revision = 0;

  Future<void> update(bool value) {
    if (_closed) return _tail;
    if (_wanted == value) return _last;
    _wanted = value;
    final revision = ++_revision;
    final job = _tail.then((_) async {
      if (_closed || revision != _revision) return;
      try {
        await _write(value).timeout(const Duration(milliseconds: 700));
      } catch (_) {
        if (revision == _revision) _wanted = null;
        rethrow;
      }
    });
    _last = job;
    _tail = job.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return job;
  }

  /// Drain an already issued write before the route releases its window.
  Future<void> close() {
    _closed = true;
    _revision++;
    return _tail;
  }
}
