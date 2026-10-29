import 'dart:async';
import 'package:yingyu/playback/stream_buffering.dart';
import 'package:yingyu/playback/disc_buffering.dart';
enum LogArea{player} enum LogLevel{warning}
class Log {void add(LogArea a,String s,{LogLevel? level}){}}
class Phase {bool fast=true;}
class Player {final state=State();}
class State {bool playing=true,buffering=false;}
class Harness {
bool opening=false,network=true,disposed=false;Object? disc;
bool get _opening=>opening;bool get _networkFile=>network;bool get _disposed=>disposed;
Object? get _disc=>disc;int _loadSerial=1,_playIntent=1;final double _speed=1;
final player=Player();final Log? log=Log();final _rates=PlaybackRateQueue((v)async{});
final _bufferPhase=Phase();final values=<String,String>{};
late final _streamBuffer=StreamBuffering(write:(k,v)async{values[k]=v;},onRestoreFailure:()=>throw StateError('restore'));
Future<void> start()=>_streamBuffer.configure(1,fast:true);
void event({bool buffering=true}){player.state.buffering=buffering;_scheduleStarvationRecovery(buffering);}
void runtime()=>_bufferPhase.fast=false;
Future<void> flush()=>_rates.run(()async{});
Future<void> block(Future<void> signal)=>_rates.run(()=>signal);
void seek()=>_playIntent++;void replace()=>_loadSerial++;
  void _scheduleStarvationRecovery(bool buffering) {
    if (!buffering) {
      _streamBuffer.endStarvation();
      return;
    }
    if (!buffering ||
        _opening ||
        _disc != null ||
        !_networkFile ||
        !player.state.playing) {
      return;
    }
    final serial = _loadSerial, intent = _playIntent;
    unawaited(
      _rates.run(() async {
        if (_disposed ||
            _opening ||
            serial != _loadSerial ||
            intent != _playIntent ||
            !player.state.playing ||
            !player.state.buffering) {
          return;
        }
        try {
          await _streamBuffer.markStarved(_speed, fast: _bufferPhase.fast);
        } catch (_) {
          log?.add(
            LogArea.player,
            '缓冲恢复目标未调整，保留原缓冲条件',
            level: LogLevel.warning,
          );
        }
      }),
    );
  }
}
