// Generated complete production resize method, platform IO substituted.
// ignore_for_file: override_on_non_overriding_member
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:synchronized/synchronized.dart';
class NativeState {bool disposed=false,active=false;}
class Handle {Future<int> get handle async=>1;}
class CanvasHarness {
  final lock=Lock();final platform=NativeState(),_nativeHdrOutput=NativeState(),_dolbyHdrOutput=NativeState();
  final player=Handle();bool _canvasClosed=false,_hasSizedSurface=true;
  int? _phoneWidth=1920,_phoneHeight=1080;
  final rect=ValueNotifier<Rect?>(const Rect.fromLTWH(0,0,1920,1080));
  final wid=ValueNotifier<int?>(900);
  final writes=<(String,String)>[];
  static const _channel=MethodChannel('synthetic/screen-canvas');
  Future<void> setProperty(String key,String value) async{writes.add((key,value));}
  void retire(){_canvasClosed=true;}
  set sized(bool v){_hasSizedSurface=v;}
  set hdr(bool v){_nativeHdrOutput.active=v;}
  (int?,int?) get canvas=>(_phoneWidth,_phoneHeight);
  Future<bool> setScreenViewport(
    int width,
    int height,
  ) => lock.synchronized(() async {
    if (_canvasClosed || platform.disposed) return false;
    if (width == 0 && height == 0 && !_hasSizedSurface) {
      _phoneWidth = _phoneHeight = null;
      return false;
    }
    if (width <= 1 || height <= 1 || width > 8192 || height > 8192) {
      return false;
    }
    if (_phoneWidth == width && _phoneHeight == height) return true;
    final beforeWidth = _phoneWidth, beforeHeight = _phoneHeight;
    _phoneWidth = width;
    _phoneHeight = height;
    if (!_hasSizedSurface) return true;
    final handle = await player.handle;
    if (_canvasClosed || platform.disposed) return false;
    Future<void> resize(int w, int h) async {
      await _channel.invokeMethod('VideoOutputManager.SetSurfaceSize', {
        'handle': handle.toString(),
        'width': w.toString(),
        'height': h.toString(),
      });
      if (_canvasClosed || platform.disposed) return;
      rect.value = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
      // A replacement wid is handled by the existing ordered listener. Updating
      // dimensions on the live context does not create a VO or pass JNI pointers.
      if (!_nativeHdrOutput.active &&
          !_dolbyHdrOutput.active &&
          (wid.value ?? 0) != 0) {
        await setProperty('android-surface-size', '${w}x$h');
      }
    }

    try {
      await resize(width, height);
    } catch (_) {
      _phoneWidth = beforeWidth;
      _phoneHeight = beforeHeight;
      if (!_canvasClosed &&
          !platform.disposed &&
          beforeWidth != null &&
          beforeHeight != null) {
        await resize(beforeWidth, beforeHeight);
      }
      rethrow;
    }
    return !_canvasClosed && !platform.disposed;
  });

}
