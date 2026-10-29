// Complete actual production read method; native property/state IO only is synthetic.
// ignore_for_file: unused_field, unused_import, unused_element, prefer_final_fields
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
class PositionIO {
 final values=<String,String>{'sub-pos':'100'};
 final reads=<String>[];Future<void> Function()? onRead;
 Future<String> getProperty(String key)async{reads.add(key);await onRead?.call();return values[key]??'unavailable';}
}
class PositionState {List<String> subtitle=[];}
class PositionPlayer {final state=PositionState();}
class PositionReadHarness {
 final io=PositionIO(),player=PositionPlayer();
 bool _disposed=false,_opening=false,_subtitleAutomatic=true,_subtitleDiscEmbedded=true;
 int _loadSerial=1,_subtitlePlacementGeneration=0;
 double? _initialSubtitlePosition,_subtitleDefaultPosition;
 double? get defaultPosition=>_subtitleDefaultPosition;
 PositionIO _adjustmentPlayer()=>io;
 void retire(){_loadSerial++;}
 void manual(double value){_subtitleAutomatic=false;_initialSubtitlePosition=value;}
 void regular(){_subtitleDiscEmbedded=false;}
  Future<double> readSubtitlePosition({
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final generation = _subtitlePlacementGeneration;
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
}
