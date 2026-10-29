// ignore_for_file: prefer_final_fields, unnecessary_nullable_for_final_variable_declarations, unused_element, unused_element_parameter, unused_field, unused_import
import 'package:media_kit/media_kit.dart' show AudioTrack;
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/tracks.dart';
import 'package:yingyu/playback/audio_decode_watch.dart';
import 'package:yingyu/playback/audio_track_switch.dart';
import 'package:yingyu/playback/audio_refresh.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'package:yingyu/playback/disc_buffering.dart';
import 'package:yingyu/playback/diagnostics.dart';

class NativePlayer {
  String aid='1';
  bool bad=false,primed=false;
  final clock=Stopwatch()..start();
  Future<String> getProperty(String key) async {
    if(key=='aid')return aid;
    if(key=='audio-params/samplerate')return bad&&aid=='2'?'unknown':'48000';
    if(key=='seeking'||key=='paused-for-cache')return 'no';
    if(key=='audio-pts'&&aid=='2'&&(bad||!primed))throw StateError('audio pts unavailable');
    return (2665+clock.elapsedMilliseconds/1000).toString();
  }
}
class PlayerState { bool playing=true,buffering=false; }
class Player {
  final _platform=NativePlayer();
  dynamic get platform=>_platform;
  final state=PlayerState();
  void Function()? fault;
  final selected=<String>[];
  Future<void> setAudioTrack(AudioTrack track) async {
    selected.add(track.id);platform.aid=track.id=='auto'?'1':track.id;
    if(platform.bad&&platform.aid=='2')fault?.call();
  }
}
class Disc { final selected=Object(); }
enum LogArea { player }
enum LogLevel { warning }
class Log { void add(LogArea area,String message,{LogLevel? level}) {} }
class Position { Duration value=const Duration(seconds:2665); bool settling=false; }
class Origin { bool discDetected=false; }
class Decoder { void codecFailed(String value){} }
abstract class Command { Future<void> audio(TrackOption track); }
class Harness extends Command {
  Harness() {
    player.fault=()=>_audioDecode.fault(_runtimeClock.elapsed,playing:player.state.playing);
  }
  final player=Player();
  final _audioDecode=AudioDecodeWatch();
  final _rates=PlaybackRateQueue((_)async{});
  final _runtimeClock=Stopwatch()..start();
  final _runtimePosition=Position();
  Disc? _disc=Disc();
  final Log? log=Log();
  bool _disposed=false;
  bool _discInterrupted=false,_opening=false,_switching=false;
  Origin? _origin;
  final _subtitleFilePaths=<String>{};
  final _decoderRecovery=Decoder();
  String? _decoderOpeningError;
  String get diagnosticState=>'';
  String? _lastFailure;
  int _loadSerial=1,_seekIntent=0,_audioChangeIntent=0;
  Future<void> _audioChanges=Future.value();
  final seeks=<Duration>[];
  String? get failure=>_lastFailure;
  bool get held=>_audioDecode.trackSwitchHeld;
  int get errors=>_audioDecode.errors;
  bool get rejected=>_audioDecode.trackSwitchRejected;
  void hold(bool value)=>_audioDecode.holdForTrackSwitch(value);
  void packetError()=>_mpvError('Error decoding audio.',videoDecoder:false,audioPacket:true);
  void reject()=>_mpvError('Could not open codec.',videoDecoder:false, 
  );
  Future<void> seek(Duration value) => _seek(value);
  Future<void> _seek(Duration value,{bool freshAudio=false,bool Function()? allowed}) {
    _seekIntent++;_audioDecode.cancel();seeks.add(value);player.platform.primed=true;
    if(player.platform.bad&&player.platform.aid=='2') {
      for(var i=0;i<8;i++){player.fault?.call();}
    }
    return Future.value();
  }
  void exit() { _disposed=true; }
  void ordinary() { _disc=null; }
  void _failPlayback(String value) { _lastFailure=value; }
  Future<void> _refreshTracks() async {}
    @override
  Future<void> audio(TrackOption track) async {
    _audioDecode.cancel();
    final native = player.platform;
    if (native is! NativePlayer || _disposed) throw const AppFailure('播放会话已关闭');
    await player.setAudioTrack(track.value as AudioTrack);
    final actual = await native.getProperty('aid');
    if (track.id != 'auto' && actual != track.id ||
        track.id == 'auto' && int.tryParse(actual) == null) {
      throw const AppFailure('MPV 未确认音轨切换，请重试');
    }
    await _refreshTracks();
  }

  void _mpvError(
    String error, {
    required bool videoDecoder,
    bool audioPacket = false,
  }) {
    if (_disposed || _discInterrupted) return;
    if (_subtitleFilePaths.any(error.contains)) {
      log?.add(
        LogArea.player,
        '外挂字幕文件无法加载或解析，可在字幕菜单重试',
        level: LogLevel.warning,
      );
      return;
    }
    if (_opening && (_switching || _origin?.discDetected == true)) return;
    if (audioPacket) {
      _audioDecode.fault(
        _runtimeClock.elapsed,
        playing:
            player.state.playing &&
            !player.state.buffering &&
            !_opening &&
            !_runtimePosition.settling,
      );
      log?.add(
        LogArea.player,
        '音频包解码失败；当前媒体内等待后续音画输出核对；'
        '次数=${_audioDecode.errors}；开播=$_opening；'
        '连续错误或播放后 8 秒仍未恢复将报错，原生终止错误立即报错',
        level: LogLevel.warning,
      );
      if (_audioDecode.errors >= 8) {
        _failPlayback('音频连续解码失败，已保留观看进度');
      }
      return;
    }
    if (videoDecoder && decoderMayFallback(error)) {
      _decoderOpeningError = error;
      _decoderRecovery.codecFailed(error);
      log?.add(
        LogArea.player,
        '视频解码器初始化失败：$error；等待当前媒体内的后备解码；'
        '${_opening ? "开播期限保持不变" : "恢复最多等待 30 秒"}',
        level: LogLevel.warning,
      );
      return;
    }
    _failPlayback(error);
  }


}
