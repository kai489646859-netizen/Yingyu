// ignore_for_file: unused_field, unused_import, unused_element, prefer_final_fields, override_on_non_overriding_member, invalid_null_aware_operator
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/picture_brightness.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';
class IO { final values=<String,String>{'gamma':'0','glsl-shaders':'','current-vo':'gpu','options/target-trc':'bt.1886','video-out-params/gamma':'bt.1886'}; final writes=<String>[];
 Future<String> getProperty(String k,{bool waitForInitialization=true})async=>values[k]??'';
 Future<void> setProperty(String k,String v,{bool waitForInitialization=true})async {writes.add(k);values[k=='file-local-options/gamma'?'gamma':k]=v;}}
class Log {void add(Object area,String text){}}
enum LogArea {player}
class PictureHarness {
 final io=IO();final log=Log();late final _shadow=ShadowEnhancement(shaderStore:(s)async {generated=s;return '/private/combined.hook';});String? generated; ShadowEnhancement get enhancement=>_shadow;
 bool _disposed=false,_opening=false;int _loadSerial=1;
 IO _adjustmentPlayer()=>io;
  @override
  Future<double> readPictureBrightness({required bool Function() allowed}) {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    return readPictureGamma(
      read: (key) => native.getProperty(key, waitForInitialization: false),
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
    );
  }

  @override
  Future<double> setPictureBrightness(
    double value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final actual = await writePictureGamma(
      value: value,
      read: (key) => native.getProperty(key, waitForInitialization: false),
      write: (key, value) =>
          native.setProperty(key, value, waitForInitialization: false),
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
    );
    log?.add(LogArea.player, '本次画面提亮：gamma=$actual；仅当前文件，HDR/杜比输出方式保持');
    return actual;
  }

}
