import 'dart:async';
import 'observation.dart';

class _RateRequest {
  _RateRequest(this.value, this.source);
  final double value;
  final SpeedChangeSource source;
  final done = Completer<void>();
}

/// Retain only the latest unstarted intent. An executing native command is
/// allowed to finish; the next command never overlaps it or claims its result.
class RateRequests {
  RateRequests({
    required this.current,
    required this.apply,
    required this.changed,
    required this.record,
  });
  final double Function() current;
  final Future<void> Function(double, SpeedChangeSource) apply;
  final void Function() changed;
  final void Function(String) record;
  _RateRequest? _pending, _running;
  bool _closed = false;

  double get target => _pending?.value ?? _running?.value ?? current();
  double? get pending => _pending?.value ?? _running?.value;

  Future<void> request(double value, SpeedChangeSource source) {
    if (_closed) return Future.value();
    final previous = _pending;
    _pending = null;
    if (previous != null) {
      record('合并未执行倍速：${previous.value}→$value');
      previous.done.complete();
    }
    final request = _RateRequest(value, source);
    _pending = request;
    // Playback speed never waits for a debounce timer. Only the independent
    // disc prefetch budget may retain its previous tier for a short period.
    _drain();
    changed();
    return request.done.future;
  }

  Future<void> flush() {
    final request = _pending;
    _drain();
    return request?.done.future ?? _running?.done.future ?? Future.value();
  }

  void _drain() {
    if (_closed || _running != null || _pending == null) return;
    final request = _pending!;
    _pending = null;
    _running = request;
    unawaited(_execute(request));
  }

  Future<void> _execute(_RateRequest request) async {
    try {
      if (request.value != current()) {
        await apply(request.value, request.source);
      }
      request.done.complete();
    } catch (error, stack) {
      request.done.completeError(error, stack);
    } finally {
      _running = null;
      if (!_closed) {
        changed();
        _drain();
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _pending?.done.complete();
    _pending = null;
    try {
      await _running?.done.future;
    } catch (_) {
      // The initiating caller retains its failure; closing still disposes.
    }
  }
}
