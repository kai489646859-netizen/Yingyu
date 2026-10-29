// Complete production native event handler, real verifier, synthetic IO.
// ignore_for_file: unused_field, prefer_final_fields, library_private_types_in_public_api
import 'dart:async';
import 'package:media_kit/media_kit.dart' show NativePlaybackEvent;
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:yingyu/playback/diagnostics.dart';
import 'package:yingyu/playback/latency_probe.dart';
import 'package:yingyu/playback/decoder_recovery.dart';
enum LogArea {player}
enum LogLevel {warning,error}
class Log {void add(LogArea area,String text,{LogLevel? level}){}}
class State {Duration duration=const Duration(seconds:100);Duration position=Duration.zero;bool buffering=false;}
class Player {final state=State();}
class Position {bool settling=false;Duration value=Duration.zero;}
class OtherRecovery {void restarted(){} void restart(){}}
class Origin {bool discDetected=false;}
class OpeningHarness {
 PlaybackLatencyProbe? _latency;
 Log? log=Log();final player=Player();final _runtimePosition=Position();
 final _dolbyRecovery=OtherRecovery(),_bufferPhase=OtherRecovery();
 bool _disposed=false,_discInterrupted=false,_opening=true,_switching=false;
 Origin? _origin;String? _lastFailure,_decoderOpeningError;
 int _nativeSeekSerial=0,_nativeRestartSeekSerial=0;double _speed=1;
 String get diagnosticState=>'synthetic current output';
 final failures=<String>[];final recovered=<VideoOutputState>[];
 bool opened=false,frame=false,seeking=false;int reads=0;
 Completer<VideoOutputState>? pending;
 late final _decoderRecovery=DecoderRecovery(readOutput:() async {
   reads++;if(pending!=null){final reply=pending!;pending=null;return reply.future;}
   return VideoOutputState(output:'gpu',configured:true,frameAvailable:frame,seeking:seeking,hardwareDecoder:'no');
 },onFailure:_failPlayback,onRecovered:recovered.add);
 void start(){opened=false;unawaited(_decoderRecovery.beginLoad().then<void>((_){opened=true;}).catchError((Object _){}));}
 void codecFailed(){_decoderOpeningError='Could not open codec.';_decoderRecovery.codecFailed(_decoderOpeningError!);}
 void event(int id)=>_nativeEvent(NativePlaybackEvent(id));
 void runtime(){_opening=false;}
 void close(){_disposed=true;_decoderRecovery.cancel();}
 void _failPlayback(String message){failures.add(message);_lastFailure=message;}
  void _nativeEvent(NativePlaybackEvent event) {
    if (_disposed || _discInterrupted) return;
    if (_opening && (_switching || _origin?.discDetected == true)) return;
    if (event.failed) {
      log?.add(
        LogArea.player,
        'MPV 终止状态：end-file error=${event.error}',
        level: LogLevel.error,
      );
    }
    if (_lastFailure != null) return;
    _latency?.nativeEvent(
      seek: event.id == mpv.mpv_event_id.MPV_EVENT_SEEK,
      restart: event.restarted,
    );
    if (event.failed) {
      _failPlayback(
        'MPV 播放已终止：end-file error=${event.error}'
        '${_decoderOpeningError == null ? "" : "；$_decoderOpeningError"}',
      );
    } else if (event.id == mpv.mpv_event_id.MPV_EVENT_END_FILE &&
        event.reason == mpv.mpv_end_file_reason.MPV_END_FILE_REASON_EOF &&
        !_opening &&
        !_runtimePosition.settling &&
        prematureMediaEnd(_runtimePosition.value, player.state.duration)) {
      _failPlayback('媒体在片尾之前提前结束，请重试；已有观看进度保留');
    } else if (event.outputChanged) {
      if (event.id == mpv.mpv_event_id.MPV_EVENT_SEEK) ++_nativeSeekSerial;
      _decoderRecovery.outputChanged(
        seeking: event.id == mpv.mpv_event_id.MPV_EVENT_SEEK,
      );
      log?.add(
        LogArea.player,
        'MPV 视频输出配置变化；位置=${player.state.position.inMilliseconds} ms；倍速=$_speed；开播=$_opening',
      );
    } else if (event.restarted) {
      _nativeRestartSeekSerial = _nativeSeekSerial;
      _dolbyRecovery.restarted();
      _decoderRecovery.restarted();
      _bufferPhase.restart();
      log?.add(
        LogArea.player,
        'MPV 播放重启事件；位置=${player.state.position.inMilliseconds} ms；倍速=$_speed；缓冲=${player.state.buffering}；$diagnosticState',
      );
    }
  }

}
