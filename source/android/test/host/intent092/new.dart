// ignore_for_file: unused_element, library_private_types_in_public_api, prefer_final_fields, unnecessary_nullable_for_final_variable_declarations, unused_element_parameter, unused_field, unused_import
// Generated complete production methods with native/player IO substitutes.
// Nullable fields reproduce the production optional IO collaborators.
import 'dart:async';
import 'package:yingyu/playback/latency_probe.dart';
import 'package:yingyu/playback/audio_refresh.dart';
import 'package:yingyu/playback/disc_buffering.dart';
import 'package:yingyu/playback/dolby_recovery.dart';
import 'package:yingyu/playback/dolby_source.dart';
import 'package:yingyu/playback/hardware_fallback.dart';
import 'package:yingyu/playback/position_guard.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'package:yingyu/playback/disc_clock_recovery.dart';
import 'package:yingyu/playback/startup_seek.dart';
import 'package:yingyu/playback/opening_subtitles.dart';
import 'package:yingyu/playback/disc_startup.dart';

enum LogArea { player }
enum LogLevel { warning }
class AppFailure implements Exception {
  const AppFailure(this.message);
  final String message;
}
class _Log {
  final rows=<String>[];
  void add(LogArea area,String text,{LogLevel? level})=>rows.add(text);
}
class NativePlayer {
  final values=<String,String>{
    'hwdec-current':'mediacodec', 'hr-seek-framedrop':'no',
    'vf':'[]', 'deinterlace':'no', 'demuxer-seekable-cache':'auto', 'hr-seek-demuxer-offset':'0.000000', 'seeking':'no', 'demuxer-cache-duration':'4', 'demuxer-cache-idle':'no','eof-reached':'no',
  };
  final commands=<String>[];
  Future<void> Function(String)? beforeRead;
  Future<void> Function(String,String)? beforeWrite;
  Future<String> getProperty(String key,{bool waitForInitialization=true}) async {
    commands.add('read:$key');
    await beforeRead?.call(key);
    return values[key]??'';
  }
  Future<void> setProperty(String key,String value) async {
    commands.add('write:$key=$value');
    await beforeWrite?.call(key,value);
    values[key]=value;
  }
}
class _State { bool playing=false,buffering=false; }
class _Player {
  _Player(this.platform);
  final Object platform;
  final state=_State();
  final seeks=<Duration>[];
  Future<void> Function(Duration)? beforeSeek;
  int playCalls=0,pauseCalls=0,openCalls=0;
  Future<void> seek(Duration target) async {
    seeks.add(target);
    await beforeSeek?.call(target);
  }
  Future<void> play() async { playCalls++; state.playing=true; }
  Future<void> pause() async { pauseCalls++; state.playing=false; }
  Future<void> open(Object _) async { openCalls++; }
}
class _Clock { Duration elapsed=Duration.zero; }
class _Reader { void stopWarming(){} }
class _Transport { final reader=_Reader(); int seeks=0; void seek()=>seeks++; }
class _Disc {
  Object? selected=Object();
  void setBuffering(bool value) {}
  int resets=0,stops=0;
  void resetReadAhead()=>resets++;
  void stopPersistentReadAhead()=>stops++;
}
class _Cancel { void suspend(){} int calls=0; void cancel()=>calls++; }
class _Observation { int generation=0; void invalidate()=>generation++; }
abstract class _Harness {
  PlaybackLatencyProbe? _latency;
  void _beginLatency(String phase, Duration target) {
    _latency?.begin(phase:phase,target:target,producer:false);
  }
  set latency(PlaybackLatencyProbe value) { _latency=value; }
  _Harness({Object? platform}):player=_Player(platform??NativePlayer());
  final _Player player;
  final _runtimeClock=_Clock();
  final _dolbyRecovery=DolbySeekRecovery();
  final _runtimePosition=PlaybackPositionGuard();
  final _runtimeWatch=RuntimeHealthWatch();
  final _discClockFault=DiscClockRecoveryEvidence();
  final _hardwareFallback=HardwareFallbackWatch();
  final _audioDecode=_Cancel(),_rateProbe=_Cancel();
  final _observation=_Observation();
  final _startupSeek=StartupSeekSetup();
  final _openingSubtitleRead=OpeningSubtitleRead();
  final _bufferWatch=DiscBufferWatch();
  final _rates=PlaybackRateQueue((_) async {});
  final _Log? log=_Log();
  final _Transport? _cachedTransport=_Transport();
  _Disc? _disc=_Disc();
  final failures=<String>[];
  final bufferReasons=<String>[];
  bool _disposed=false,_opening=false,_discInterrupted=false;
  bool _runtimeRepairBusy=false,_dolbyMapping=true;
  final double _speed=1;
  int _runtimeEpoch=0,_seekIntent=0,_loadSerial=1,_playIntent=0,emits=0,armed=0,cancelledBuffer=0;
  int _nativeSeekSerial=0,_nativeRestartSeekSerial=0;
  bool _audioRefreshBroken=false;
  int? _fastSeekNativeSerial;
 int? _fastSeekIntent;
  Duration? _seekSince;
  String? _lastFailure;
  Future<void> Function(String)? beforeBuffer;
  NativePlayer get native=>player.platform as NativePlayer;
  DolbySeekRecovery get recovery=>_dolbyRecovery;
  Duration get position=>_runtimePosition.value;
  Duration? get seekSince=>_seekSince;
  bool get busy=>_runtimeRepairBusy;
  String? get failure=>_lastFailure;
  List<String> get logs=>log!.rows;
  int get intent=>_seekIntent;
  int get epoch=>_runtimeEpoch;
  void at(int ms)=>_runtimeClock.elapsed=Duration(milliseconds:ms);
  void setPlaying(bool value) {
    player.state.playing=value;
    _dolbyRecovery.playbackChanged(now:_runtimeClock.elapsed,playing:value);
  }
  void setOpening(bool value)=>_opening=value;
  void invalidateMedia() {
    _opening=true;
    _runtimeEpoch++;
    _loadSerial++;
    _discClockFault.clear();
    _dolbyRecovery.reset();
  }
  void close() { _disposed=true; _dolbyRecovery.cancel(); }
  void interrupt()=>_discInterrupted=true;
  void fatal(String message)=>_failPlayback(message);
  void ordinaryMedia()=>_dolbyMapping=false;
  Future<void> hold(Future<void> gate)=>_rates.run(()=>gate);

  Future<void> seek(Duration position);
  Future<void> internalSeek(Duration position);
  bool _initialDiscCushionUsed=false,_readAheadAllowed=false;
  DateTime? _phonePlayingSince;
  void _updatePersistentReadAhead() {}
  Future<void> play();
  Future<void> pause();
  void ordinary(){_disc=null;}
  void restarted(){_nativeSeekSerial++;_nativeRestartSeekSerial=_nativeSeekSerial;}
  void emit()=>emits++;
  void _armBufferPhase()=>armed++;
  void _cancelBufferPhase()=>cancelledBuffer++;
  Future<void> _beginFastBuffer(String reason) async {
    bufferReasons.add(reason);
    await beforeBuffer?.call(reason);
  }
  void _failPlayback(String message) {
    if(_disposed||_discInterrupted||_lastFailure!=null)return;
    _lastFailure=message;
    failures.add(message);
  }
}

class Harness extends _Harness {
  @override
  Future<void> play() async {
    final intent = ++_playIntent;
    final serial = _loadSerial;
    final native = player.platform;
    if (!_initialDiscCushionUsed &&
        _disc?.selected != null &&
        native is NativePlayer) {
      _initialDiscCushionUsed = true;
      final clock = Stopwatch()..start();
      final result = await waitForDiscCushion(
        read: (key) => native.getProperty(key, waitForInitialization: false),
        active: () =>
            !_disposed && intent == _playIntent && serial == _loadSerial,
      );
      if (!_disposed && serial == _loadSerial) {
        _disc?.setBuffering(player.state.buffering);
      }
      log?.add(
        LogArea.player,
        '首次播放供数衔接：$result；等待=${clock.elapsedMilliseconds} ms',
      );
    }
    if (_disposed || intent != _playIntent || serial != _loadSerial) return;
    if (native is NativePlayer) {
      await _openingSubtitleRead.restore(
        read: native.getProperty,
        write: native.setProperty,
      );
      if (_disposed || intent != _playIntent || serial != _loadSerial) return;
    }
    _phonePlayingSince ??= DateTime.now();
    _readAheadAllowed = true;
    await player.play();
    _updatePersistentReadAhead();
  }

  @override
  Future<void> pause() async {
    ++_playIntent;
    _audioDecode.suspend();
    _phonePlayingSince = null;
    _readAheadAllowed = false;
    _cachedTransport?.reader.stopWarming();
    _disc?.stopPersistentReadAhead();
    await player.pause();
  }

  @override
  Future<void> seek(Duration position) => _seek(position, cancelPlay: true);

  Future<void> _seek(
    Duration position, {
    bool cancelPlay = false,
    bool freshAudio = false,
    bool Function()? allowed,
  }) {
    // Internal audio priming must not cancel an already requested initial play.
    // Explicit user seeks retain their existing cancellation semantics.
    _latency?.finish('new_seek_intent');
    if (cancelPlay) ++_playIntent;
    final intent = ++_seekIntent;
    _discClockFault.clear();
    _dolbyRecovery.cancel();
    _audioDecode.cancel();
    _hardwareFallback.cancel();
    _cachedTransport?.seek();
    _disc?.stopPersistentReadAhead();
    _rateProbe.cancel();
    _observation.invalidate();
    // Invalidate a pending first-frame sample immediately, before waiting for
    // an earlier rate operation. It must not promote the old seek's cache.
    _cancelBufferPhase();
    return _rates.run(() async {
      if (_audioRefreshBroken) {
        throw const AppFailure('音轨刷新参数恢复失败，请退出播放器后重试');
      }
      if (_disposed || intent != _seekIntent || allowed?.call() == false) {
        return;
      }
      _observation.invalidate();
      ++_runtimeEpoch;
      _runtimeWatch.seek();
      _discClockFault.begin(
        load: _loadSerial,
        epoch: _runtimeEpoch,
        intent: intent,
      );
      final previous = _runtimePosition.value;
      _runtimePosition.beginSeek(position);
      _seekSince = _runtimeClock.elapsed;
      _bufferWatch.reset();
      try {
        _beginLatency(freshAudio ? 'audio_refresh' : 'seek', position);
        await _beginFastBuffer('定位');
        if (_disposed || intent != _seekIntent) return;
        final native = player.platform;
        if (native is NativePlayer) {
          _fastSeekIntent = intent;
          await _startupSeek.prepare(
            read: (key) => native
                .getProperty(key)
                .timeout(const Duration(milliseconds: 600)),
            write: (key, value) => native
                .setProperty(key, value)
                .timeout(const Duration(seconds: 2)),
          );
        }
        if (_disposed || intent != _seekIntent) return;
        _disc?.resetReadAhead();
        _armBufferPhase();
        if (_dolbyMapping && native is NativePlayer) {
          String hardware;
          try {
            hardware = await native
                .getProperty('hwdec-current')
                .timeout(const Duration(milliseconds: 600));
          } catch (_) {
            hardware = '';
          }
          if (_disposed || intent != _seekIntent) return;
          _dolbyRecovery.beginSeek(
            target: position,
            now: _runtimeClock.elapsed,
            hardware: hardware,
            playing: player.state.playing,
            speed: _speed,
          );
        }
        // A command reply is not a completed seek. Keep pre-target discard
        // until this seek has emitted a real SEEK followed by PLAYBACK_RESTART.
        _fastSeekNativeSerial = _nativeSeekSerial;
        if (freshAudio && native is NativePlayer) {
          final seekSerial = _nativeSeekSerial;
          await freshAudioSeek(
            read: native.getProperty,
            write: native.setProperty,
            seek: () => player.seek(position),
            restarted: () => _nativeRestartSeekSerial > seekSerial,
            active: () =>
                !_disposed && intent == _seekIntent && allowed?.call() != false,
          );
          if (!_disposed && intent == _seekIntent && allowed?.call() != false) {
            log?.add(LogArea.player, '原盘音轨刷新已核对：本次定位与重启完成，临时缓存及预滚参数已恢复');
          }
        } else {
          await player.seek(position);
        }
      } on AudioRefreshRestoreFailure catch (error) {
        // Fail inside the queue before another seek/load can use dirty options.
        _audioRefreshBroken = true;
        if (!_disposed) _failPlayback(error.toString());
        rethrow;
      } catch (_) {
        if (intent == _seekIntent) {
          _runtimePosition.reset(previous);
          _seekSince = null;
          _dolbyRecovery.cancel();
        }
        rethrow;
      }
    });
  }

  Future<double?> displaySourceFps() async {
    final native = player.platform;
    if (_disposed || native is! NativePlayer) return null;
    final serial = _loadSerial;
    final value = double.tryParse(await native.getProperty('container-fps'));
    if (_disposed ||
        serial != _loadSerial ||
        value == null ||
        !value.isFinite ||
        value < 1 ||
        value > 240) {
      return null;
    }
    return value;
  }


  @override Future<void> internalSeek(Duration position) => _seek(position);

  Future<void> freshSeek(Duration position) => _seek(position, freshAudio:true);
}
