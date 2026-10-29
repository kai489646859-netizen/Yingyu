// ignore_for_file: unused_field, unused_import, unused_element, prefer_final_fields, override_on_non_overriding_member, invalid_null_aware_operator
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/picture_brightness.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';
import 'package:yingyu/playback/enhancement_output.dart';
class IO { final values=<String,String>{'gamma':'0','glsl-shaders':'','current-vo':'gpu','options/target-trc':'bt.1886','video-out-params/gamma':'bt.1886'}; final writes=<String>[];
 Future<String> getProperty(String k,{bool waitForInitialization=true})async=>values[k]??'';
 Future<void> setProperty(String k,String v,{bool waitForInitialization=true})async {writes.add(k);values[k=='file-local-options/gamma'?'gamma':k]=v;}}
class Log {void add(Object area,String text){}}
enum LogArea {player}
class PictureHarness {
 final io=IO();final log=Log();late final _shadow=ShadowEnhancement(shaderStore:(s)async {generated=s;return '/private/combined.hook';});String? generated; ShadowEnhancement get enhancement=>_shadow;
 bool _disposed=false,_opening=false;int _loadSerial=1;
 final _noticeDecoded=<String,String>{};int _enhancementRenderFault=0;
 IO _adjustmentPlayer()=>io;
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
