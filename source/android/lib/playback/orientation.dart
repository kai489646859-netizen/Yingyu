import 'package:flutter/services.dart';

/// A lease lasts for the whole player page, including retries and episode changes.
class PlaybackOrientation {
  static const channel = MethodChannel('yingyu/orientation');
  static int _next = DateTime.now().microsecondsSinceEpoch;
  final int _owner = ++_next;
  bool _released = false;
  Future<void>? _releaseJob;
  bool phone = false;
  Future<void> enter() => _send(true);
  Future<void> release() {
    if (_released) return Future.value();
    return _releaseJob ??= () async {
      try {
        await _send(false);
        _released = true;
      } finally {
        _releaseJob = null;
      }
    }();
  }

  Future<void> finishExit() async {
    try {
      await channel.invokeMethod<void>('finishExit', {'owner': _owner});
    } on MissingPluginException {
      /* Offline/non-Android. */
    }
  }

  Future<void> _send(bool active) async {
    try {
      final result = await channel.invokeMapMethod<Object?, Object?>('player', {
        'owner': _owner,
        'active': active,
      });
      if (active) phone = result?['phone'] == true;
    } on MissingPluginException {
      // The platform bridge is absent in offline widget tests and non-Android hosts.
    }
  }
}
