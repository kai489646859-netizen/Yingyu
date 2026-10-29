import 'package:yingyu/playback/native_hdr.dart' show DolbyHdrRecovery;
// ignore_for_file: unused_field, prefer_final_fields, library_private_types_in_public_api, unused_element_parameter
import 'package:media_kit/media_kit.dart' show NativePlaybackEvent;
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:yingyu/playback/diagnostics.dart';
import 'package:yingyu/playback/latency_probe.dart';
enum LogArea {network,player}
enum LogLevel {warning,error}
class _Log {void add(LogArea area,String text,{LogLevel? level}){}}
class _Message {const _Message(this.prefix,this.level,this.text);final String prefix,level,text;}
class _State {Duration duration=const Duration(seconds:100);Duration position=const Duration(seconds:20);bool buffering=false;}
class _Player {final state=_State();}
class _Position {bool settling=false;Duration value=const Duration(seconds:20);}
class _Recovery {void outputChanged({required bool seeking}){} void restarted(){} void restart(){}}
class _Origin {bool discDetected=false;}
class ErrorBackendHarness {
 final _autoHdrRecovery = DolbyHdrRecovery();
 PlaybackLatencyProbe? _latency;
 _Log? log=_Log();final player=_Player();final _runtimePosition=_Position();
 final _decoderRecovery=_Recovery(),_dolbyRecovery=_Recovery(),_bufferPhase=_Recovery();
 bool _disposed=false,_discInterrupted=false,_opening=false,_switching=false,_readEofReported=false;
 _Origin? _origin;String? _lastFailure,_decoderOpeningError;
 int _nativeSeekSerial=0,_nativeRestartSeekSerial=0;double _speed=1.5;
 String get diagnosticState=>'synthetic cached playback';
 final errors=<String>[];
 void _failPlayback(String message){errors.add(message);_lastFailure=message;}
 void _mpvError(String message,{required bool videoDecoder,bool audioDecoder=false,bool audioPacket=false})=>_failPlayback(message);
 bool isAudioTrackInitError(String prefix,String level,String text)=>false;
 bool isAudioPacketError(String prefix,String level,String text)=>false;
 void route(String prefix,String level,String text){final log=_Message(prefix,level,text);
         if (isTransportReadEof(log.prefix, log.level, log.text) &&
            !_readEofReported) {
          _readEofReported = true;
          this.log?.add(
            LogArea.network,
            '媒体读取返回 EOF（0xdfb9b0bb）；保留已有缓存播放，等待内核终止事件判定；$diagnosticState',
            level: LogLevel.warning,
          );
        }
        if (isTransportReadTimeout(log.prefix, log.level, log.text)) {
          this.log?.add(
            LogArea.network,
            '媒体读取超时（ETIMEDOUT）；继续缓存播放，交由内核现有重连处理；'
            '最终终止和提前结束仍报错；$diagnosticState',
            level: LogLevel.warning,
          );
        }
        if (isTransportConnectionAbort(log.prefix, log.level, log.text)) {
          this.log?.add(
            LogArea.network,
            '媒体连接中断（ECONNABORTED/-103）；保留缓存与当前暂停状态，'
            '等待内核现有有界重连结果；最终终止和提前结束仍报错；$diagnosticState',
            level: LogLevel.warning,
          );
        }
        if (isMpvErrorLog(log.prefix, log.level, log.text) &&
            !_autoHdrRecovery.holdsInitializationError(log.prefix, log.text)) {
          _mpvError(
            mpvOpenFailure(log.prefix, log.text) ?? log.text,
            videoDecoder: log.prefix == 'vd',
            audioDecoder: isAudioTrackInitError(
              log.prefix,
              log.level,
              log.text,
            ),
            audioPacket: isAudioPacketError(log.prefix, log.level, log.text),
          );
        }

 }
 void nativeEvent(NativePlaybackEvent e)=>_nativeEvent(e);
 void position(Duration value){_runtimePosition.value=value;}
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
