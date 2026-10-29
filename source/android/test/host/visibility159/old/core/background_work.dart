import 'dart:async';
import 'package:flutter/foundation.dart';
import 'models.dart';

class BackgroundPaused extends AppFailure {
  const BackgroundPaused() : super('浏览任务已暂停');
}

/// A scope for optional browsing work. Playback requests are outside this zone.
/// Pausing aborts current HTTP bodies as well as rejecting queued requests.
class BackgroundWork extends ChangeNotifier {
  static final _zoneKey = Object();
  static BackgroundWork? get current =>
      Zone.current[_zoneKey] as BackgroundWork?;
  final _owners = <Object>{};
  final _requests = <Completer<void>>{};
  bool get paused => _owners.isNotEmpty;

  Future<T> run<T>(Future<T> Function() action) {
    if (paused) return Future.error(const BackgroundPaused());
    return runZoned(action, zoneValues: {_zoneKey: this});
  }

  void attach(Completer<void> abort) {
    if (paused) throw const BackgroundPaused();
    _requests.add(abort);
  }

  void detach(Completer<void> abort) => _requests.remove(abort);

  void pause(Object owner, bool value) {
    final before = paused;
    value ? _owners.add(owner) : _owners.remove(owner);
    if (before == paused) return;
    if (paused) {
      for (final request in _requests.toList()) {
        if (!request.isCompleted) request.complete();
      }
    }
    notifyListeners();
  }
}
