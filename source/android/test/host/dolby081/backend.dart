// ignore_for_file: library_private_types_in_public_api, prefer_final_fields, unnecessary_nullable_for_final_variable_declarations, unused_element_parameter, unused_field, unused_import
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
    'vf':'[]', 'deinterlace':'no',
  };
  final commands=<String>[];
  Future<void> Function(String)? beforeRead;
  Future<void> Function(String,String)? beforeWrite;
  Future<String> getProperty(String key) async {
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
class _State { bool playing=true; }
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
class _Transport { int seeks=0; void seek()=>seeks++; }
class _Disc {
  int resets=0,stops=0;
  void resetReadAhead()=>resets++;
  void stopPersistentReadAhead()=>stops++;
}
class _Cancel { int calls=0; void cancel()=>calls++; }
class _Observation { int generation=0; void invalidate()=>generation++; }
abstract class _Harness {
  PlaybackLatencyProbe? _latency;
  void _beginLatency(String phase, Duration target) {}
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
  final _bufferWatch=DiscBufferWatch();
  final _rates=PlaybackRateQueue((_) async {});
  final _Log? log=_Log();
  final _Transport? _cachedTransport=_Transport();
  final _Disc? _disc=_Disc();
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
  Future<void> fault(DolbyOutputFailure issue,{String code='hardware_mapping'}) =>
      (this as DolbyBackendHarness)._handleDolbyOutputFailure(issue,code);
  Future<void> seek(Duration position);
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

class DolbyBackendHarness extends _Harness {
  DolbyBackendHarness({super.platform});
  Future<void> _handleDolbyOutputFailure(
    DolbyOutputFailure issue,
    String code,
  ) async {
    if (_disposed || _discInterrupted || _lastFailure != null) return;
    log?.add(
      LogArea.player,
      '杜比输出诊断：类别=$code；定位代次=${_dolbyRecovery.generation}；'
      '目标=${_dolbyRecovery.target.inMilliseconds} ms；已用恢复=${_dolbyRecovery.attempted}',
      level: LogLevel.warning,
    );
    // Classify synchronously at log arrival. Waiting for a property read here
    // could turn an already queued warning into a post-rebuild failure.
    // The recorded decoder is checked against MPV again before any rebuild.
    final action = _dolbyRecovery.fault(
      issue,
      now: _runtimeClock.elapsed,
      opening: _opening,
      currentHardware: _dolbyRecovery.hardware,
      playing: player.state.playing,
    );
    if (action == DolbyRecoveryAction.fail) {
      _failPlayback(switch (issue) {
        DolbyOutputFailure.pairing => '杜比画面与色彩信息配对失败，已停止播放并保留观看进度',
        DolbyOutputFailure.capability => '杜比硬解画面输出不可用，已停止播放并保留观看进度',
        _ => '杜比画面输出未能恢复，已停止播放并保留观看进度',
      });
      return;
    }
    if (action != DolbyRecoveryAction.rebuildHardware) return;
    final native = player.platform;
    if (native is! NativePlayer) {
      _failPlayback('杜比定位恢复时原生播放器不可用，已保留观看进度');
      return;
    }
    final generation = _dolbyRecovery.generation;
    final intent = _seekIntent;
    bool active() =>
        !_disposed &&
        !_opening &&
        !_discInterrupted &&
        _lastFailure == null &&
        generation == _dolbyRecovery.generation &&
        intent == _seekIntent;
    try {
      await _rates.run(() async {
        if (!active()) return;
        final actual = await native
            .getProperty('hwdec-current')
            .timeout(const Duration(milliseconds: 600));
        if (!active()) return;
        if (actual != _dolbyRecovery.hardware ||
            !const {'mediacodec', 'mediacodec-copy'}.contains(actual)) {
          throw const AppFailure('杜比定位恢复前的实际解码器已变化');
        }
        if (!_dolbyRecovery.repairStarted(
          generation: generation,
          now: _runtimeClock.elapsed,
        )) {
          if (active()) {
            _failPlayback('杜比定位恢复超过原定位期限，已保留观看进度');
          }
          return;
        }
        _runtimeRepairBusy = true;
        try {
          ++_runtimeEpoch;
          _runtimeWatch.seek();
          _discClockFault.begin(
            load: _loadSerial,
            epoch: _runtimeEpoch,
            intent: _seekIntent,
          );
          _hardwareFallback.cancel();
          _observation.invalidate();
          final target = _dolbyRecovery.target;
          _runtimePosition.beginSeek(target);
          _seekSince ??= _runtimeClock.elapsed;
          log?.add(
            LogArea.player,
            '杜比定位映射恢复：当前媒体内仅一次原硬解重建；'
            '目标=${target.inMilliseconds} ms；实际解码=$actual；不重新解析入口',
            level: LogLevel.warning,
          );
          await _beginFastBuffer('杜比定位恢复');
          if (!active()) return;
          _cachedTransport?.seek();
          _disc?.resetReadAhead();
          _armBufferPhase();
          await repairHardwareFallback(
            action: HardwareRepairAction.retryHardware,
            hardware: actual,
            position: target,
            active: active,
            write: native.setProperty,
            seek: player.seek,
          );
          if (!active()) return;
          _dolbyRecovery.repairCompleted(generation: generation);
          log?.add(LogArea.player, '杜比定位恢复命令完成；等待新的播放重启与目标位置连续音画，命令完成不代表恢复成功');
        } finally {
          _runtimeRepairBusy = false;
        }
      });
    } catch (_) {
      if (active()) {
        _dolbyRecovery.cancel();
        _failPlayback('杜比定位后的硬解重建失败，已保留观看进度');
      }
    } finally {
      if (!_disposed) emit();
    }
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

}
