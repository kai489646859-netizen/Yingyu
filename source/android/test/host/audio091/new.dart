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
  void reject()=>_mpvError('Could not open codec.',videoDecoder:false, audioDecoder:true,
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
  Future<void> audio(TrackOption track) {
    final intent = ++_audioChangeIntent;
    final load = _loadSerial;
    var seekIntent = _seekIntent;
    bool active() =>
        !_disposed &&
        _lastFailure == null &&
        load == _loadSerial &&
        intent == _audioChangeIntent &&
        seekIntent == _seekIntent;
    final result = _audioChanges.then((_) async {
      final native = player.platform;
      if (native is! NativePlayer || !active()) {
        throw const AppFailure('音轨操作已取消');
      }
      _audioDecode.cancel();
      _audioDecode.holdForTrackSwitch(true);
      final codec = normalizedCodec(track.codec);
      final safeCodec =
          const {
            'aac',
            'ac3',
            'eac3',
            'truehd',
            'dts',
            'flac',
            'opus',
            'vorbis',
            'mp3',
            'pcm_s16le',
            'pcm_s24le',
            'pcm_s32le',
          }.contains(codec)
          ? codec
          : '其他或未提供';
      log?.add(
        LogArea.player,
        '音轨切换请求：编码=$safeCodec；原盘=${_disc?.selected != null}；等待原生输出核对',
      );
      try {
        final status = await switchAudioTrack(
          requested: track.id,
          disc: _disc?.selected != null,
          read: native.getProperty,
          select: (id) => _rates.run(() async {
            if (!active()) throw const AudioSwitchCancelled();
            await player.setAudioTrack(
              id == track.id
                  ? track.value as AudioTrack
                  : AudioTrack(id, null, null),
            );
          }),
          refresh: () async {
            if (!active()) throw const AudioSwitchCancelled();
            final value = await native
                .getProperty('time-pos')
                .timeout(const Duration(milliseconds: 600));
            if (!active()) throw const AudioSwitchCancelled();
            final target = mediaClock(value) ?? _runtimePosition.value;
            final job = _seek(
              target,
              freshAudio: _disc?.selected != null,
              allowed: active,
            );
            seekIntent = _seekIntent;
            await job;
          },
          active: active,
          playing: () => player.state.playing,
          packetErrors: () => _audioDecode.errors,
          decoderRejected: () => _audioDecode.trackSwitchRejected,
          record: (message) => log?.add(LogArea.player, message),
        );
        if (status != AudioSwitchResult.deferred) _audioDecode.cancel();
        if (active()) {
          await _refreshTracks();
          log?.add(LogArea.player, '音轨输出核对：${status.name}；暂停不自动播放；倍速与字幕设置保持');
        }
      } on AudioSwitchCancelled {
        throw const AppFailure('音轨操作已被定位、换片或退出取消');
      } on AudioRefreshRestoreFailure catch (error) {
        if (active()) _failPlayback(error.toString());
        throw AppFailure(error.toString());
      } on AudioSwitchFailure catch (error) {
        if (active()) {
          await _refreshTracks();
          if (error.restored) {
            _audioDecode.cancel();
            log?.add(LogArea.player, error.toString(), level: LogLevel.warning);
          } else {
            _failPlayback(error.toString());
          }
        }
        throw AppFailure(error.toString());
      } finally {
        _audioDecode.holdForTrackSwitch(false);
      }
    });
    _audioChanges = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _mpvError(
    String error, {
    required bool videoDecoder,
    bool audioDecoder = false,
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
    if (audioDecoder && !audioPacket && _audioDecode.trackSwitchHeld) {
      _audioDecode.rejectTrackSwitch();
      log?.add(
        LogArea.player,
        '所选音轨解码初始化失败，当前切换事务将核对并有界回退；真实终止错误保持',
        level: LogLevel.warning,
      );
      return;
    }
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
        '${_audioDecode.trackSwitchHeld ? "切换中由有界输出核对和回退处理" : "连续错误或播放后 8 秒仍未恢复将报错"}，原生终止错误立即报错',
        level: LogLevel.warning,
      );
      if (_audioDecode.errors >= 8 && !_audioDecode.trackSwitchHeld) {
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
