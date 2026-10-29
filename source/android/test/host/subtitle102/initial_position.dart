// Full configure method and guarded load-time preference block.
// Only enclosing player state/native IO are synthetic; no media is opened.
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/log.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
class InitialIo {
 final values=<String,String>{'sub-pos':'100','yingyu-subtitle-below-picture':'no','sid':'no','sub-delay':'1.5','target-trc':'pq'};
 final writes=<String>[];bool reject=false,rejectReset=false;void Function()? afterWrite;
 Future<String> getProperty(String key)async{if(reject)throw StateError('synthetic read rejection');return values[key]!;}
 Future<void> setProperty(String key,String value)async{if(rejectReset && key=='yingyu-subtitle-below-picture')throw StateError('synthetic reset rejection');writes.add(key);values[key]=value;afterWrite?.call();}
}
class InitialPositionHarness implements InitialSubtitlePositionBackend {
 bool _disposed=false,_opening=false,_subtitleAutomatic=true;int _loadSerial=0;
 double? _initialSubtitlePosition,_regularSubtitlePosition;final bool _subtitleDiscEmbedded=false;DiagnosticLog? log;final io=InitialIo();
 SubtitleViewConfiguration _subtitleViewConfiguration=const SubtitleViewConfiguration();
 bool get automatic=>_subtitleAutomatic;
 Alignment get alignment=>_subtitleViewConfiguration.alignment;
 double? get regularPosition=>_regularSubtitlePosition;
 void retire(){_loadSerial++;}
 void opening(){_opening=true;}
 void dispose(){_disposed=true;}
 @override
  void configureSubtitlePosition(double? value) {
    if (_disposed || _opening || _loadSerial != 0) return;
    if (value != null && (!value.isFinite || value < 0 || value > 100)) {
      throw const AppFailure('字幕位置须在 0% 到 100% 之间');
    }
    _initialSubtitlePosition = value;
    _regularSubtitlePosition = value;
    _subtitleAutomatic = value == null;
    _subtitleViewConfiguration = SubtitleViewConfiguration(
      alignment: value == null
          ? Alignment.bottomCenter
          : Alignment(0, 1 - value / 50),
    );
  }
 Future<void> apply()async{
 final native=io;final serial=_loadSerial;final remembered=_initialSubtitlePosition;
          if (remembered != null) {
            try {
              await writeMpvSubtitlePosition(
                value: remembered,
                read: native.getProperty,
                write: native.setProperty,
                active: () => !_disposed && serial == _loadSerial,
              );
            } catch (_) {
              // A stale/unsupported preference must not prevent media opening.
              if (_disposed || serial != _loadSerial) rethrow;
              try {
                final defaults = _subtitleDiscEmbedded
                    ? const {
                        'stretch-image-subs-to-screen': 'no',
                        'sub-pos': '100',
                        'yingyu-subtitle-below-picture': 'no',
                        'yingyu-subtitle-screen-position': 'no',
                      }
                    : const {'yingyu-subtitle-below-picture': 'yes'};
                for (final entry in defaults.entries) {
                  if (_disposed || serial != _loadSerial) {
                    throw const AppFailure('播放会话已改变');
                  }
                  await native.setProperty(entry.key, entry.value);
                }
              } catch (_) {
                // Position is optional; a failed preference must not turn an
                // otherwise healthy movie into a playback error.
              }
              _subtitleAutomatic = true;
              _initialSubtitlePosition = null;
              _subtitleViewConfiguration = const SubtitleViewConfiguration();
              log?.add(
                LogArea.player,
                '字幕位置记忆未确认，已尝试恢复默认；可在字幕位置中重新调整',
                level: LogLevel.warning,
              );
            }
          }
 }
}
