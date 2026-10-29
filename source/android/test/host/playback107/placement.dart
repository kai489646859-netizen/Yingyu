// Complete current backend position methods; only player IO is synthetic.
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
class PositionIo {
 final values=<String,String>{'yingyu-subtitle-below-picture':'yes','yingyu-subtitle-screen-position':'yes','stretch-image-subs-to-screen':'yes','sub-pos':'100','sid':'no'};
 final writes=<String>[];void Function()? afterWrite;
 Future<String> getProperty(String key)async=>values[key]!;
 Future<void> setProperty(String key,String value)async{writes.add(key);values[key]=value;afterWrite?.call();}
}
class PositionState {List<String> subtitle=[];}
class PositionPlayer {final state=PositionState();}
class PlacementHarness implements SubtitlePositionBackend,DefaultSubtitlePositionBackend {
 final io=PositionIo();final player=PositionPlayer();double? _subtitleDefaultPosition,_initialSubtitlePosition,_regularSubtitlePosition,_discSubtitlePosition;bool _subtitleAutomatic=true;final bool _disposed=false,_opening=false;int _loadSerial=0,_subtitlePlacementGeneration=0,emits=0;
 bool _subtitleDiscEmbedded=false;
 void disc(){_subtitleDiscEmbedded=true;}
 void textPosition(double value){_subtitleDefaultPosition=value;player.state.subtitle=['synthetic dialogue'];}
 SubtitleViewConfiguration _subtitleViewConfiguration=const SubtitleViewConfiguration();
 SubtitleViewConfiguration get configuration=>_subtitleViewConfiguration;
 double? get rememberedPosition=>_initialSubtitlePosition;
 double? get regularPosition=>_regularSubtitlePosition;
 double? get discPosition=>_discSubtitlePosition;
 void changeTrack(){_subtitlePlacementGeneration++;}
 @override bool get usesDefaultSubtitlePosition=>_subtitleAutomatic;
 PositionIo _adjustmentPlayer()=>io;
 void emit(){emits++;}
 void retire(){_loadSerial++;}
  @override
  Future<double> readSubtitlePosition({
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final generation = _subtitlePlacementGeneration;
    if (!_subtitleAutomatic && _initialSubtitlePosition != null) {
      if (!allowed() || _disposed || _opening) {
        throw const AppFailure('播放会话已改变');
      }
      return _initialSubtitlePosition!;
    }
    if (_subtitleAutomatic &&
        !player.state.subtitle.any((line) => line.trim().isNotEmpty)) {
      double? measured;
      try {
        measured = double.tryParse(
          await native.getProperty('yingyu-subtitle-position'),
        );
      } catch (_) {
        // No active bitmap composition is an unknown baseline, not screen 0%.
      }
      if (!allowed() ||
          _disposed ||
          _opening ||
          serial != _loadSerial ||
          generation != _subtitlePlacementGeneration) {
        throw const AppFailure('播放会话已改变');
      }
      if (measured != null &&
          measured.isFinite &&
          measured >= 0 &&
          measured <= 100) {
        _subtitleDefaultPosition = 100 - measured;
      }
      if (_subtitleDefaultPosition == null) {
        throw const SubtitlePositionPending();
      }
      return _subtitleDefaultPosition!;
    }
    final actual = await readMpvSubtitlePosition(
      read: native.getProperty,
      active: () =>
          allowed() &&
          !_disposed &&
          !_opening &&
          serial == _loadSerial &&
          generation == _subtitlePlacementGeneration,
    );
    return _subtitleAutomatic &&
            !_subtitleDiscEmbedded &&
            _subtitleDefaultPosition != null &&
            player.state.subtitle.any((line) => line.trim().isNotEmpty)
        ? _subtitleDefaultPosition!
        : actual;
  }

  @override
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final generation = _subtitlePlacementGeneration;
    bool active() =>
        allowed() &&
        !_disposed &&
        !_opening &&
        serial == _loadSerial &&
        generation == _subtitlePlacementGeneration;
    await writeMpvSubtitleLayout(
      scope: _subtitleDiscEmbedded
          ? SubtitlePositionScope.discEmbedded
          : SubtitlePositionScope.regular,
      position: value,
      read: native.getProperty,
      write: native.setProperty,
      active: active,
    );
    if (!active()) throw const AppFailure('播放会话已改变');
    _subtitleAutomatic = false;
    _initialSubtitlePosition = value;
    if (_subtitleDiscEmbedded) {
      _discSubtitlePosition = value;
    } else {
      _regularSubtitlePosition = value;
    }
    _subtitleViewConfiguration = SubtitleViewConfiguration(
      alignment: Alignment(0, 1 - value / 50),
    );
    emit();
    return value;
  }

  @override
  Future<double> resetSubtitlePosition({
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final generation = _subtitlePlacementGeneration;
    bool active() =>
        allowed() &&
        !_disposed &&
        !_opening &&
        serial == _loadSerial &&
        generation == _subtitlePlacementGeneration;
    await writeMpvSubtitleLayout(
      scope: _subtitleDiscEmbedded
          ? SubtitlePositionScope.discEmbedded
          : SubtitlePositionScope.regular,
      read: native.getProperty,
      write: native.setProperty,
      active: active,
    );
    if (!active()) throw const AppFailure('播放会话已改变');
    _subtitleAutomatic = true;
    _initialSubtitlePosition = null;
    if (_subtitleDiscEmbedded) {
      _discSubtitlePosition = null;
    } else {
      _regularSubtitlePosition = null;
    }
    _subtitleViewConfiguration = const SubtitleViewConfiguration();
    emit();
    return readSubtitlePosition(allowed: allowed);
  }

}
