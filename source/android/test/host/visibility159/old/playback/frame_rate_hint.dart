import 'dart:async';
import 'package:flutter/services.dart';

/// One bounded source-FPS read per playback owner; ordered optional local IPC.
/// Media speed, video size/precision, decoding and dropping stay with MPV.
class PlaybackFrameRateHints {
  PlaybackFrameRateHints({
    Future<Map<dynamic, dynamic>?> Function(Map<String, Object>)? send,
    this.record,
  }) : send =
           send ??
           ((value) => const MethodChannel(
             'yingyu/device',
           ).invokeMapMethod('playbackRate', value));
  final Future<Map<dynamic, dynamic>?> Function(Map<String, Object>) send;
  final void Function(String)? record;
  static int _serial = 0;
  int _token = 0, _revision = 0;
  Object? _owner;
  double _speed = 1;
  double? _fps;
  bool _active = false, _closed = false, _readStarted = false;
  Future<void> _tail = Future.value();
  void _queue(Map<String, Object> value, int revision, {bool release = false}) {
    _tail = _tail.then((_) async {
      if (!release && (_closed || revision != _revision)) return;
      try {
        final reply = await send(
          value,
        ).timeout(const Duration(milliseconds: 500));
        if (_closed || revision != _revision || value['active'] != true) return;
        final status = reply?['status'];
        if (const {
          'requested',
          'unchanged',
          'capacity-limited',
          'unavailable',
          'suspended',
        }.contains(status)) {
          final hz = reply?['requestedHz'];
          final requested = hz is num && hz.isFinite && hz > 0 && hz <= 1000
              ? hz.toStringAsFixed(3)
              : '未提供';
          record?.call(
            '显示帧率提示：片源=${_fps?.toStringAsFixed(3)} fps；倍速=$_speed；请求=$requested Hz；状态=$status；系统可忽略请求，非实际呈现帧率',
          );
        }
      } catch (_) {
        if (!_closed && revision == _revision && value['active'] == true) {
          record?.call('显示帧率提示不可用，继续原播放');
        }
      }
    });
  }

  void _publish() {
    if (_closed || _token == 0) return;
    _queue({
      'owner': _token,
      'fps': _fps ?? 0,
      'speed': _speed,
      'active': _active && _fps != null,
      'retire': false,
    }, _revision);
  }

  void update({
    required Object owner,
    required double speed,
    required bool active,
    required Future<double?> Function() readFps,
  }) {
    if (_closed) return;
    final wanted = active && speed > 1;
    final changed = !identical(owner, _owner);
    if (!changed && speed == _speed && wanted == _active) return;
    _revision++;
    if (changed) {
      if (_token != 0) {
        _queue(
          {'owner': _token, 'active': false, 'retire': true},
          _revision,
          release: true,
        );
      }
      _owner = owner;
      _token = ++_serial;
      _fps = null;
      _readStarted = false;
    }
    _speed = speed;
    _active = wanted;
    if (_active && !_readStarted) {
      _readStarted = true;
      final token = _token;
      unawaited(() async {
        double? fps;
        try {
          fps = await readFps().timeout(const Duration(milliseconds: 250));
        } catch (_) {}
        if (_closed || token != _token) return;
        if (fps != null && fps.isFinite && fps >= 1 && fps <= 240) _fps = fps;
        _publish();
      }());
    } else {
      _publish();
    }
  }

  Future<void> close() {
    if (!_closed) {
      _closed = true;
      _revision++;
      if (_token != 0) {
        _queue(
          {'owner': _token, 'active': false, 'retire': true},
          _revision,
          release: true,
        );
      }
    }
    return _tail;
  }
}
