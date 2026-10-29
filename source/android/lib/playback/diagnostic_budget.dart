/// No timer of its own. Safety watchdogs retain their existing cadence.
class DiagnosticBudget {
  final _last = <String, Duration>{};
  bool stopped = false;
  static String nativeFamily(String text) {
    final match = RegExp(
      r'Yingyu ([a-zA-Z0-9_]+)(?: (?:name|layer)=([a-zA-Z0-9_]+))?',
    ).firstMatch(text);
    return 'native:${match?[1] ?? "other"}:${match?[2] ?? ""}';
  }

  bool allow(
    String family,
    Duration now, {
    bool enabled = true,
    bool playing = true,
    bool abnormal = false,
    Duration interval = const Duration(seconds: 10),
  }) {
    if (stopped || !enabled || !playing) return false;
    final before = _last[family];
    final gap = abnormal ? const Duration(seconds: 2) : interval;
    if (before != null && now >= before && now - before < gap) return false;
    if (!_last.containsKey(family) && _last.length >= 64) {
      _last.remove(_last.keys.first);
    }
    _last[family] = now;
    return true;
  }

  void stop() {
    stopped = true;
  }

  void reset() {
    stopped = false;
    _last.clear();
  }
}

abstract class PlaybackDiagnosticLifecycle {
  /// Synchronous invalidation before progress/network or decoder teardown waits.
  void stopDiagnostics();
}
