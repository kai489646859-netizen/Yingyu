import 'dart:io';
import 'package:flutter/services.dart';

class SystemMedia {
  static const channel = MethodChannel('yingyu/media-control');
  static int _sequence = 0;
  int owner = 0;
  Object? _lastState;
  Duration? _position;
  bool _shown = false;

  void bind(Future<void> Function(MethodCall) command) {
    if (Platform.isAndroid) channel.setMethodCallHandler(command);
  }

  void renew() {
    clear();
    owner = ++_sequence;
  }

  Future<void> _send(String method, Map<String, Object> arguments) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      // System UI is optional; a vendor failure must not interrupt playback.
    } on MissingPluginException {
      // No native media integration on this engine.
    }
  }

  void update({
    required String title,
    required String mode,
    required Duration position,
    required Duration duration,
    required double speed,
    required bool interactive,
  }) {
    if (!Platform.isAndroid || owner == 0) return;
    final state = (title, mode, duration.inSeconds, speed, interactive);
    if (_lastState == state &&
        _position != null &&
        (position - _position!).abs() < const Duration(seconds: 1)) {
      return;
    }
    _lastState = state;
    _position = position;
    _shown = true;
    _send('state', {
      'owner': owner,
      'title': title,
      'mode': mode,
      'position': position.inMilliseconds,
      'duration': duration.inMilliseconds,
      'speed': speed,
      'interactive': interactive,
    });
  }

  void clear() {
    if (!_shown) return;
    _shown = false;
    _lastState = null;
    _position = null;
    _send('clear', {'owner': owner});
  }

  void dispose() {
    clear();
    if (Platform.isAndroid && owner == _sequence) {
      channel.setMethodCallHandler(null);
    }
  }
}
