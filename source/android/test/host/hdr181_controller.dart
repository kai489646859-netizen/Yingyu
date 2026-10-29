// Complete production controller HDR entry and output owner initializer; only engine IO is substituted.
// ignore_for_file: curly_braces_in_flow_control_structures, prefer_final_fields, unused_element, unused_field, override_on_non_overriding_member
import 'dart:ui' show Rect;
import 'package:synchronized/synchronized.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/native_hdr_output.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/dolby_hdr_output.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/dolby_output.dart';
class Config {String? vo='gpu';}
class Controller181 {
 Controller181([Engine181? io]):platform=io??Engine181();
 final Engine181 platform;final lock=Lock(), configuration=Config();
 final _dolbyOutput=DolbyOutputSetup(),_dolbyHdrOutput=DolbyHdrOutput();
 int _hdrEpoch=0,_dolbyHdrEpoch=0; int? _phoneWidth;
 bool _canvasClosed=false;
 void Function(String,String)? _hdrProgress;
 final wid=ValueNotifier<int?>(900),rect=ValueNotifier<Rect?>(const Rect.fromLTWH(0,0,1920,1080));
 set mapped(bool v){_dolbyOutput.enabled=v;platform.vo=v?'gpu-next':'gpu';}
 Future<void> setProperty(String k,String v)=>platform.setOutputProperty(k,v);
 String get status=>_nativeHdrOutput.status;
 Future<bool> attempt(String transfer)=>setNativeHdrSurface(token:7,width:1920,height:1080,transfer:transfer,fill:false);
 Future<bool> restore()=>setNativeHdrSurface(token:0,width:1,height:1,transfer:'pq',fill:false);
  late final _nativeHdrOutput = NativeHdrOutput(
    renderer: () => _dolbyOutput.enabled ? 'gpu-next' : 'gpu',
    additionalOwnerActive: () => _dolbyHdrOutput.active,
    cancelAdditionalOwner: _dolbyHdrOutput.cancelForClose,
    detachAdditionalOwner: () =>
        _dolbyHdrOutput.detach(platform.setOutputProperty),
    onProgress: (stage, detail) => _hdrProgress?.call(stage, detail),
    refresh: (position) =>
        platform.refreshOutputFrame(position, epoch: _hdrEpoch),
    current: () =>
        !_canvasClosed &&
        !platform.disposed &&
        platform.outputEpoch == _hdrEpoch,
  );
  Future<bool> setNativeHdrSurface({
    required int token,
    required int width,
    required int height,
    required String transfer,
    required bool fill,
    void Function(String stage, String detail)? onProgress,
  }) => lock.synchronized(() async {
    if (_canvasClosed || platform.disposed) {
      _nativeHdrOutput.status = 'admission-controller-closed';
      return false;
    }
    _hdrEpoch = platform.outputEpoch;
    if (token != 0 && _dolbyHdrOutput.active) {
      _nativeHdrOutput.status = 'admission-preloaded-owner-active';
      return false;
    }
    _hdrProgress = onProgress;
    try {
      return await _nativeHdrOutput.apply(
        surface: token,
        width: width,
        height: height,
        transfer: transfer,
        fill: fill,
        keepPanscan: _phoneWidth != null,
        textureSurface: wid.value ?? 0,
        textureWidth: rect.value?.width.toInt() ?? 1,
        textureHeight: rect.value?.height.toInt() ?? 1,
        originalOutput: _dolbyOutput.output(configuration.vo!),
        read: platform.getOutputProperty,
        write: platform.setOutputProperty,
      );
    } finally {
      _hdrProgress = null;
    }
  });
  Future<bool> setPreloadedDolbyHdrSurface({
    required int token,
    required int width,
    required int height,
    required String transfer,
    required bool fill,
    String position = '0',
    double peak = 0,
  }) => lock.synchronized(() async {
    if (_canvasClosed || platform.disposed) {
      return _dolbyHdrOutput.reject('controller-closed');
    }
    if (token == 0) {
      final epoch = platform.outputEpoch;
      await _dolbyHdrOutput.restore(
        texture: wid.value ?? 0,
        width: rect.value?.width.toInt() ?? 1,
        height: rect.value?.height.toInt() ?? 1,
        read: platform.getOutputProperty,
        write: platform.setOutputProperty,
        recover: true,
        current: () =>
            !_canvasClosed &&
            !platform.disposed &&
            platform.outputEpoch == epoch,
        refresh: (anchor) => platform.refreshOutputFrame(anchor, epoch: epoch),
      );
      return false;
    }
    if (!_dolbyOutput.enabled) {
      return _dolbyHdrOutput.reject('mapping-disabled');
    }
    if (!const {'pq', 'hlg'}.contains(transfer)) {
      return _dolbyHdrOutput.reject('transfer-unsupported');
    }
    if (_dolbyHdrOutput.active) {
      if (_dolbyHdrOutput.token != token) return false;
      return _dolbyHdrOutput.resize(
        width: width,
        height: height,
        fill: fill,
        read: platform.getOutputProperty,
        write: platform.setOutputProperty,
      );
    }
    _dolbyHdrEpoch = platform.outputEpoch;
    return _dolbyHdrOutput.arm(
      surface: token,
      width: width,
      height: height,
      position: position,
      transfer: transfer,
      peak: peak,
      fill: fill,
      keepPanscan: _phoneWidth != null,
      texture: wid.value ?? 0,
      textureWidth: rect.value?.width.toInt() ?? 1,
      textureHeight: rect.value?.height.toInt() ?? 1,
      read: (key) => platform.getProperty(key, waitForInitialization: false),
      write: setProperty,
      current: () =>
          !_canvasClosed &&
          !platform.disposed &&
          platform.outputEpoch == _dolbyHdrEpoch,
    );
  });
  Future<bool> confirmPreloadedDolbyHdr() => lock.synchronized(
    () async =>
        !_canvasClosed &&
        !platform.disposed &&
        platform.outputEpoch == _dolbyHdrEpoch &&
        await _dolbyHdrOutput.confirmed(platform.getOutputProperty),
  );
}

class Engine181 {
 bool disposed=false, rejectPq=false;int outputEpoch=1,refills=0;
 String vo='gpu',selected='1';
 final writes=<(String,String)>[];
 final values=<String,String>{'gpu-context':'','target-prim':'bt.709','target-trc':'bt.1886','target-peak':'auto','tone-mapping':'bt.2390','dither':'fruit','dither-depth':'8','panscan':'0','vid':'auto','video-output-levels':'auto','wid':'900','hr-seek-framedrop':'no'};
 Future<void> refreshOutputFrame(String p,{required int epoch})async{refills++;}
 Future<String> getProperty(String k,{bool waitForInitialization=true})=>getOutputProperty(k);
 Future<String> getOutputProperty(String k)async{
  if(k=='file-format')return 'mkv';
  if(k=='yingyu-preloaded-dolby-vision-profile'||k=='current-tracks/video/dolby-vision-profile')return '5';
  if(k=='vid')return selected;
  if(k=='pause')return 'yes';if(k=='aid')return '1';
  if(k=='seeking'||k=='idle-active')return 'no';if(k=='seekable')return 'yes';if(k=='time-pos')return '42.125';
  if(k=='vf')return '[]';if(k=='deinterlace')return 'no';
  final ready=const {'gpu','gpu-next'}.contains(vo)&&selected!='no'&&!(rejectPq&&values['gpu-context']=='android-hdr-pq');
  if(k=='current-vo')return ready?vo:'null';if(k=='vo-configured')return ready?'yes':'no';if(k=='video-frame-info/interlaced')return ready?'no':'';
  if(k=='options/vo')return vo;
  if(k.startsWith('options/'))return values[k.substring(8)]??'';
  return values[k]??'';
 }
 Future<void> setOutputProperty(String k,String v)async{
  if(k=='target-peak' && v!='auto' && int.tryParse(v)==null){throw StateError('MPV integer choice rejected');}
  writes.add((k,v));if(k=='vo'){vo=v;}else if(k=='vid'){selected=v=='no'?'no':'1';values[k]=v;}else{values[k]=v;}
 }
}
