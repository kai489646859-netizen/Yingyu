import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/core/log.dart';
class NativePlayer {
 final values=<String,String>{'sub-pos':'100','yingyu-subtitle-screen-position':'yes','yingyu-subtitle-below-picture':'yes','stretch-image-subs-to-screen':'yes','sid':'1','sub-visibility':'yes','sub-delay':'1.5','target-trc':'pq'};
 final writes=<String>[];String? reject;bool refused=false;void Function()? afterWrite;
 Future<String> getProperty(String key)async=>values[key]!;
 Future<void> setProperty(String key,String value)async{writes.add(key);if(key==reject && !refused){refused=true;return;}values[key]=value;afterWrite?.call();}
}
class ScopeDisc {Object? selected=Object();}
class PlacementPlayer {dynamic platform;}
class PhoneLayoutFit {
 PhoneLayoutFit(this.io);final NativePlayer io;
 Future<void> configure({required bool fill})async{io.values['stretch-image-subs-to-screen']='yes';}
}
class ScreenLayoutFit {Future<void> set(bool fill)async{}}
class SubtitleScopeHarness implements InitialSubtitlePositionBackend,ScopedSubtitlePositionBackend {
 final io=NativePlayer();ScopeDisc? _disc;
 final player=PlacementPlayer();PhoneLayoutFit? _phoneFit;ScreenLayoutFit? _screenFit;bool _pictureFill=false;
 bool get filled=>_pictureFill;
 void phone(){player.platform=io;_phoneFit=PhoneLayoutFit(io);}
 void tablet(){player.platform=io;_screenFit=ScreenLayoutFit();}
 DiagnosticLog? log;
 final bool _screenCanvas=true;bool _disposed=false,_opening=false,_subtitleAutomatic=true,_subtitleDiscEmbedded=false;
 int _loadSerial=0,_subtitlePlacementGeneration=0,emits=0;double? _initialSubtitlePosition,_regularSubtitlePosition,_discSubtitlePosition,_subtitleDefaultPosition;
 final _externalIds=<String,String>{};final _trackMetadata=<String,({bool external})>{};
 SubtitleViewConfiguration _subtitleViewConfiguration=const SubtitleViewConfiguration();
 bool get discEmbedded=>_subtitleDiscEmbedded;bool get automatic=>_subtitleAutomatic;
 double? get position=>_initialSubtitlePosition;double? get defaultPosition=>_subtitleDefaultPosition;
 Alignment get alignment=>_subtitleViewConfiguration.alignment;
 @override SubtitlePositionScope get subtitlePositionScope=>_subtitleDiscEmbedded?SubtitlePositionScope.discEmbedded:SubtitlePositionScope.regular;
 void useDisc(){_disc=ScopeDisc();}
 void external(String actual){_externalIds['public-sub']=actual;}
 void metadataExternal(String actual){_trackMetadata['sub:$actual']=(external:true);}
 void emit(){emits++;}
 void retire(){_loadSerial++;}
 void dispose(){_disposed=true;}
 void opening(){_opening=true;}
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
 @override
  void configureDiscSubtitlePosition(double? value) {
    if (_disposed || _opening || _loadSerial != 0) return;
    if (value != null && (!value.isFinite || value < 0 || value > 100)) {
      throw const AppFailure('字幕位置须在 0% 到 100% 之间');
    }
    _discSubtitlePosition = value;
  }
  void _selectSubtitlePlacement(bool discEmbedded) {
    _subtitleDiscEmbedded = discEmbedded;
    _subtitleDefaultPosition = null;
    final value = discEmbedded
        ? _discSubtitlePosition
        : _regularSubtitlePosition;
    _initialSubtitlePosition = value;
    _subtitleAutomatic = value == null;
    _subtitleViewConfiguration = SubtitleViewConfiguration(
      alignment: value == null
          ? Alignment.bottomCenter
          : Alignment(0, 1 - value / 50),
    );
  }
  Future<void> _applySubtitleLayoutForTrack(
    TrackOption track,
    String actual,
    NativePlayer native,
    bool Function() active,
  ) async {
    if (!_screenCanvas || actual == 'no') return;
    final discEmbedded =
        _disc?.selected != null &&
        !track.external &&
        track.value is! ExternalSubtitle &&
        track.value is! LocalSubtitle &&
        !_externalIds.values.contains(actual) &&
        _trackMetadata['sub:$actual']?.external != true;
    if (discEmbedded == _subtitleDiscEmbedded) return;
    await writeMpvSubtitleLayout(
      scope: discEmbedded
          ? SubtitlePositionScope.discEmbedded
          : SubtitlePositionScope.regular,
      position: discEmbedded ? _discSubtitlePosition : _regularSubtitlePosition,
      read: native.getProperty,
      write: native.setProperty,
      active: active,
    );
    if (!active()) throw const AppFailure('字幕操作已取消');
    _selectSubtitlePlacement(discEmbedded);
    emit();
  }
  Future<void> setPhoneFill(bool fill) async {
    final serial = _loadSerial, generation = _subtitlePlacementGeneration;
    if (_phoneFit != null) {
      await _phoneFit!.configure(fill: fill);
    } else {
      await _screenFit?.set(fill);
    }
    final native = player.platform;
    if (!_disposed &&
        serial == _loadSerial &&
        generation == _subtitlePlacementGeneration &&
        _subtitleDiscEmbedded &&
        _subtitleAutomatic &&
        native is NativePlayer) {
      await writeMpvSubtitleLayout(
        scope: SubtitlePositionScope.discEmbedded,
        read: native.getProperty,
        write: native.setProperty,
        active: () =>
            !_disposed &&
            serial == _loadSerial &&
            generation == _subtitlePlacementGeneration,
      );
    }
    if (!_disposed) {
      _pictureFill = fill;
      emit();
    }
  }
 Future<void> initialize()async{
 _selectSubtitlePlacement(_disc?.selected!=null);
 final native=io;final serial=_loadSerial;
if (_subtitleDiscEmbedded && _subtitleAutomatic) {
            await writeMpvSubtitleLayout(
              scope: SubtitlePositionScope.discEmbedded,
              read: native.getProperty,
              write: native.setProperty,
              active: () => !_disposed && serial == _loadSerial,
            );
          } else {
            await native.setProperty('yingyu-subtitle-screen-position', 'yes');
            if (await native.getProperty('yingyu-subtitle-screen-position') !=
                'yes') {
              throw const AppFailure('字幕屏幕位置初始化失败');
            }
            final placement = _subtitleAutomatic ? 'yes' : 'no';
            await native.setProperty(
              'yingyu-subtitle-below-picture',
              placement,
            );
            if (await native.getProperty('yingyu-subtitle-below-picture') !=
                placement) {
              throw const AppFailure('字幕默认位置初始化失败');
            }
          }

 final remembered=_initialSubtitlePosition;
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
 Future<void> selectTrack(TrackOption track,String actual)async{
 _subtitlePlacementGeneration++;
 final serial=_loadSerial;
 await _applySubtitleLayoutForTrack(track,actual,io,()=>!_disposed && serial==_loadSerial);
 }
}
