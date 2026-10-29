// Complete production methods; no Android/native media is loaded.
// ignore_for_file: override_on_non_overriding_member, unused_field, prefer_final_fields, invalid_null_aware_operator, prefer_interpolation_to_compose_strings
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';
import 'package:yingyu/playback/enhancement_output.dart';
class Io {
 final values=<String,String>{'current-vo':'gpu-next','glsl-shaders':'','options/target-trc':'bt.1886','video-out-params/gamma':'pq'};
 final writes=<String>[];final sync=<String>[];
 bool render=true;int frame=0;String rendered='';
 Future<String> getProperty(String key,{bool waitForInitialization=true})async {
  if(key=='yingyu-enhancement-state')return jsonEncode({'frame':frame,'valid':render,'shader':rendered});
  if(key=='vo-passes')return jsonEncode({'fresh':[{'desc':render&&values['glsl-shaders']!.isNotEmpty?'Yingyu Dolby gain '+values['glsl-shaders']!.split('/').last.substring(0,12):'old output'}]});
  return values[key]??'';
 }
 Future<void> setProperty(String key,String value,{bool waitForInitialization=true})async {writes.add(key);if(!waitForInitialization)sync.add(key);values[key]=value;if(key=='glsl-shaders'&&render){frame++;rendered=value.isEmpty?'':value.split('/').last.substring(0,64);}}
}
class Log {final messages=<String>[];void add(Object area,String text){messages.add(text);}}
enum LogArea {player}
class EnhancementBackend {
 final io=Io(),log=Log();final _noticeDecoded=<String,String>{};
 String? generated;
 late final _shadow=ShadowEnhancement(shaderStore:(content)async {generated=content;return '/private/'+sha256.convert(utf8.encode(content)).toString()+'.hook';});
 final bool _disposed=false,_opening=false;final int _loadSerial=1;int _enhancementRenderFault=0;
 void profile(String value){_noticeDecoded['dolby-vision-profile']=value;}
 double get shadowEnhancement=>_shadow.value;
 Io _adjustmentPlayer()=>io;
  @override
  Future<double> setShadowEnhancement(
    double value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final dolby =
        useDolbyEnhancement(_noticeDecoded, 'gpu-next') &&
        await native.getProperty('current-vo') == 'gpu-next';
    bool active() =>
        allowed() && !_disposed && !_opening && serial == _loadSerial;
    final confirmation = dolby
        ? DolbyEnhancementConfirmation(
            read: native.getProperty,
            active: active,
            renderFault: () => _enhancementRenderFault,
          )
        : null;
    final actual = await _shadow.set(
      value,
      read: native.getProperty,
      write: native.setProperty,
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
      dolbyInplace: dolby,
      p7Sdr: _noticeDecoded['dolby-vision-profile'] == '7',
      prepareConfirmation: confirmation?.prepare,
      confirm: confirmation?.confirm,
    );
    log?.add(LogArea.player, '暗部增强：$actual；仅当前影片；按实际输出色彩处理，未改变解码或HDR输出方式');
    return actual;
  }

  @override
  Future<double> readPictureBrightness({
    required bool Function() allowed,
  }) async {
    _adjustmentPlayer();
    if (!allowed() || _disposed || _opening) {
      throw const AppFailure('播放会话已改变');
    }
    return _shadow.picture;
  }

  @override
  Future<double> setPictureBrightness(
    double value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final dolby =
        useDolbyEnhancement(_noticeDecoded, 'gpu-next') &&
        await native.getProperty('current-vo') == 'gpu-next';
    bool active() =>
        allowed() && !_disposed && !_opening && serial == _loadSerial;
    final confirmation = dolby
        ? DolbyEnhancementConfirmation(
            read: native.getProperty,
            active: active,
            renderFault: () => _enhancementRenderFault,
          )
        : null;
    await _shadow.set(
      _shadow.value,
      pictureBrightness: value,
      read: (key) => native.getProperty(key, waitForInitialization: dolby),
      write: (key, value) =>
          native.setProperty(key, value, waitForInitialization: dolby),
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
      dolbyInplace: dolby,
      p7Sdr: _noticeDecoded['dolby-vision-profile'] == '7',
      prepareConfirmation: confirmation?.prepare,
      confirm: confirmation?.confirm,
    );
    final actual = _shadow.picture;
    log?.add(LogArea.player, '整体亮度增强：$actual；统一线性RGB增益；仅当前文件，HDR/杜比输出方式保持');
    return actual;
  }

}
