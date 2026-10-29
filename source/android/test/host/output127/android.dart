// Complete Android preparation/listener/decoded-parameter callback; IO only fake.
import 'dart:async';
import 'package:media_kit/media_kit.dart' show VideoParams;
import 'package:synchronized/synchronized.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/dolby_output.dart';

import 'package:media_kit_video/src/video_controller/android_video_controller/surface_update.dart';
class Cell<T>{Cell(this._value);T _value;void Function()? changed;T get value=>_value;set value(T next){if(_value==next)return;_value=next;changed?.call();}}
class Rect{Rect.fromLTWH(double x,double y,this.width,this.height);final double width,height;}
class Hdr{bool active=false;}
class Config{String? vo='gpu';}
class Platform{bool disposed=false;final values=<String,String>{},readOverrides=<String,String>{};Future<String> getProperty(String k,{bool waitForInitialization=true})async=>readOverrides[k]??values[k]??'unavailable';}
class Player{Future<int> get handle async=>123;final seeks=<Duration>[];Future<void> seek(Duration p)async{seeks.add(p);}}
class Channel{
 Map<String,dynamic>? reply={'id':1,'wid':20,'width':3840,'height':2160};void Function()? beforeReply,onResize;int calls=0;
 Future<Map<K,V>?> invokeMapMethod<K,V>(String name,Map<String,String> args)async{calls++;beforeReply?.call();return reply?.cast<K,V>();}
 Future<void> invokeMethod(String name,Map<String,String> args)async{calls++;onResize?.call();}
}
class AndroidHarness{
 final lock=Lock();final rect=Cell<Rect?>(null),id=Cell<int?>(null),wid=Cell<int?>(null);
 final configuration=Config();final platform=Platform();final player=Player();
 final _channel=Channel();Channel get channel=>_channel;
 final _dolbyOutput=DolbyOutputSetup();final _nativeHdrOutput=Hdr();final _dolbyHdrOutput=Hdr();
 set dolbyHdr(bool v){_dolbyHdrOutput.active=v;}
 set hdr(bool value){_nativeHdrOutput.active=value;}
 set mapped(bool value){_dolbyOutput.enabled=value;}
 bool _canvasClosed=false,_hasSizedSurface=false,_preparingVideoSurface=false,_preparedVideoSurface=false;int _surfaceSerial=0;int? _phoneWidth,_phoneHeight;
 final waitUntilFirstFrameRenderedCompleter=Completer<void>();
 final writes=<String>[];
 AndroidHarness(){wid.changed=(){unawaited(widListener());};}
 void close(){_canvasClosed=true;}
 void phone(int w,int h){_phoneWidth=w;_phoneHeight=h;}
 Future<void> setProperty(String k,String v)async{writes.add('$k=$v');platform.values[k]=v;}
  Future<bool> prepareVideoSurface(
    int width,
    int height, [
    bool Function()? active,
  ]) async {
    if (width < 2 ||
        height < 2 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 33554432) {
      return false;
    }
    var ownsPreparation = false;
    try {
      final surface = await lock.synchronized(() async {
        if (active?.call() == false ||
            _canvasClosed ||
            platform.disposed ||
            _nativeHdrOutput.active ||
            _hasSizedSurface ||
            _preparedVideoSurface ||
            _preparingVideoSurface) {
          return 0;
        }
        ownsPreparation = true;
        _preparingVideoSurface = true;
        final serial = _surfaceSerial;
        final w = _phoneWidth ?? width, h = _phoneHeight ?? height;
        final handle = await player.handle;
        if (active?.call() == false || _canvasClosed || platform.disposed) {
          return 0;
        }
        final value = await _channel.invokeMapMethod<String, dynamic>(
          'VideoOutputManager.PrepareSurface',
          {'handle': handle.toString(), 'width': '$w', 'height': '$h'},
        );
        if (active?.call() == false ||
            _canvasClosed ||
            platform.disposed ||
            _nativeHdrOutput.active ||
            value == null ||
            value['wid'] is! int ||
            value['id'] is! int ||
            value['width'] != w ||
            value['height'] != h) {
          return 0;
        }
        final next = value['wid'] as int;
        if (next == 0 || (_surfaceSerial != serial && wid.value != next)) {
          return 0;
        }
        // The acknowledged snapshot avoids depending on Resize/result delivery
        // order. Publishing wid uses the same serialized listener as real resize.
        rect.value = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
        id.value = value['id'] as int;
        // A published header-sized Surface still needs real decoded params,
        // even when optional VO readback cannot confirm this optimization.
        _preparedVideoSurface = true;
        wid.value = next;
        return next;
      });
      if (surface == 0) return false;
      // Release the Surface lock before waiting for its queued listener. The
      // preloaded hook must never hold the lock while awaiting its own update.
      return await lock.synchronized(() async {
        if (active?.call() == false ||
            _canvasClosed ||
            platform.disposed ||
            _nativeHdrOutput.active ||
            wid.value != surface) {
          return false;
        }
        final ready =
            await platform.getProperty('wid', waitForInitialization: false) ==
                '$surface' &&
            await platform.getProperty('vo', waitForInitialization: false) ==
                _dolbyOutput.output(configuration.vo!);
        if (active?.call() == false || _canvasClosed || platform.disposed) {
          return false;
        }
        return ready;
      });
    } finally {
      if (ownsPreparation) _preparingVideoSurface = false;
    }
  }
  Future<void> widListener() async {
    final serial = ++_surfaceSerial;
    Duration? refreshPosition;
    await lock.synchronized(() async {
      // Several Surface callbacks can queue while a Dolby/output transaction
      // owns the lock. Only the newest callback owns the current Surface;
      // replaying the others rebuilds that same VO and decoder repeatedly.
      if (serial != _surfaceSerial || _canvasClosed || platform.disposed) {
        return;
      }
      if (_nativeHdrOutput.active || _dolbyHdrOutput.active) return;
      final width = rect.value?.width.toInt() ?? 1;
      final height = rect.value?.height.toInt() ?? 1;
      final surface = wid.value ?? 0;
      await updateAndroidSurface(
        wid: surface,
        width: width,
        height: height,
        output: _dolbyOutput.output(configuration.vo!),
        read: (key) => platform.getProperty(key, waitForInitialization: false),
        write: setProperty,
        seek: (position) async {
          refreshPosition = position;
        },
        refreshFrame: _hasSizedSurface,
      );
      if (surface != 0 && width > 1 && height > 1) {
        if (!_preparingVideoSurface) _hasSizedSurface = true;
      }
    });
    // Do not hold the output lock while a player command awaits its event.
    // on_preloaded must acquire this lock before it can release the mpv hook.
    if (serial == _surfaceSerial &&
        refreshPosition != null &&
        !_canvasClosed &&
        !platform.disposed) {
      await player.seek(refreshPosition!);
    }
  }
Future<void> parameters(VideoParams event)=>lock.synchronized(()async{
        if (_canvasClosed || platform.disposed) return;
        int width;
        int height;
        if (event.rotate == 0 || event.rotate == 180) {
          width = event.dw ?? 0;
          height = event.dh ?? 0;
        } else {
          // width & height are swapped for 90 or 270 degrees rotation.
          width = event.dh ?? 0;
          height = event.dw ?? 0;
        }

        if (width > 0 && height > 0 && _phoneWidth != null) {
          width = _phoneWidth!;
          height = _phoneHeight!;
        }

        final isZero = width == 0 || height == 0;
        final isSame =
            width == rect.value?.width.toInt() &&
            height == rect.value?.height.toInt();
        if (isZero) return;
        if (_dolbyHdrOutput.active) {
          if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
            waitUntilFirstFrameRenderedCompleter.complete();
          }
          return;
        }
        if (isSame) {
          if (_preparedVideoSurface) {
            _hasSizedSurface = true;
            if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
              waitUntilFirstFrameRenderedCompleter.complete();
            }
          }
          return;
        }

        final handle = await player.handle;

        await _channel.invokeMethod('VideoOutputManager.SetSurfaceSize', {
          'handle': handle.toString(),
          'width': width.toString(),
          'height': height.toString(),
        });

        rect.value = Rect.fromLTWH(
          0.0,
          0.0,
          width.toDouble(),
          height.toDouble(),
        );

        if (!waitUntilFirstFrameRenderedCompleter.isCompleted) {
          waitUntilFirstFrameRenderedCompleter.complete();
        }
});
}
