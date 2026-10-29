// ignore_for_file: unused_element, library_private_types_in_public_api, override_on_non_overriding_member, prefer_final_fields, unused_element_parameter, unused_field, unused_import
// Complete production methods. Only player/native and unrelated IO are substitutes.
import 'dart:async';
import 'package:yingyu/playback/latency_probe.dart';
import 'package:yingyu/playback/audio_refresh.dart';
import 'lib/playback/runtime_health.dart';
import 'lib/playback/position_guard.dart';
import 'lib/playback/hardware_fallback.dart';
import 'lib/playback/audio_decode_watch.dart';
import 'lib/playback/dolby_recovery.dart';
import 'lib/playback/startup_seek.dart';
import 'lib/playback/disc_buffering.dart';
import 'lib/playback/observation.dart';
import 'lib/playback/disc_buffer_phase.dart';
import 'lib/core/models.dart';
import 'lib/playback/disc_clock_recovery.dart';
import 'package:yingyu/playback/render_metrics.dart';
import 'package:yingyu/playback/diagnostic_budget.dart';
enum LogArea { player }
enum LogLevel { warning }
class _Log {
  bool get enabled => true;
  final rows = <String>[];
  void add(LogArea area, String text, {LogLevel? level}) => rows.add(text);
}
class NativePlayer {
  final values = <String, String>{'hr-seek-framedrop':'yes', 'vf':'', 'deinterlace':'no'};
  final writes = <(String, String)>[];
  Future<void> Function(String)? beforeRead;
  Future<void> Function()? beforeWrite;
  bool failWrite = false;
  Future<String> getProperty(String key) async {
    await beforeRead?.call(key);
    return values[key] ?? 'unavailable';
  }
  Future<void> setProperty(String key, String value) async {
    writes.add((key, value));
    await beforeWrite?.call();
    if (failWrite) throw StateError('synthetic property rejection');
    values[key] = value;
  }
}
class _State {
  Duration position = Duration.zero, duration = const Duration(seconds:8246);
  bool playing=true, buffering=false,completed=false;
  int? width=3840, height=2160;
}
class _Player {
  Object platform=NativePlayer();
  final state=_State();
  final seeks=<Duration>[];
  final rates=<double>[];
  bool failRate=false;
  Future<void> seek(Duration value) async { seeks.add(value); state.position=value; }
  Future<void> setRate(double value) async { rates.add(value); if(failRate) throw StateError('synthetic native rate rejection'); }
}
class _Clock { Duration elapsed=Duration.zero; }
class _Cell<T> { T value; _Cell(this.value); }
class _Rect { double width=3840,height=2160; }
class _Video { final rect=_Cell<_Rect?>(_Rect()),id=_Cell<int?>(1); }
class _Cache { int seeks=0; void seek()=>seeks++; }
class _Disc {
  _Disc(this.selected); Object? selected; int resets=0;
  void resetReadAhead()=>resets++;
  void stopPersistentReadAhead() {}
}
class _Noop { void cancel() {} void reset() {} void speed(double value,{bool retainPeak=true}) {} void start(double from,double to) {} }
class _BufferPhase { bool fast=false, promotionFailed=false; }
class _StreamBuffer {
  String? get snapshot => applied;
  Future<void> restoreSnapshot(String? value) => restore(value);
 String? applied;
 Future<void> configure(double value,{required bool fast}) async {}
 Future<void> restore(String? previous) async {}
}
class BackendHarness {
  PlaybackLatencyProbe? _latency;
  void _beginLatency(String phase, Duration target) {}
  final player=_Player(), video=_Video(), _runtimeClock=_Clock();
  NativePlayer get native => player.platform as NativePlayer;
  final _runtimePosition=PlaybackPositionGuard(), _runtimeWatch=RuntimeHealthWatch();
  final _hardwareFallback=HardwareFallbackWatch(), _dolbyRecovery=DolbySeekRecovery();
  final _audioDecode=AudioDecodeWatch(), _observation=PlaybackObservation();
  final _startupSeek=StartupSeekSetup(), _rateProbe=_Noop(), _bufferWatch=_Noop();
  final _cache=_Cache();
  _Cache? get _cachedTransport=>_cache;
  late final _rates=PlaybackRateQueue(_applyRate);
  final _bufferPhase=_BufferPhase(), _streamBuffer=_StreamBuffer(), _readAhead=_Noop();
  final _networkFile=true;
  DiscBufferPlan? _appliedDiscPlan;
  Future<DiscBufferPlan> _discPlan(double value,{required bool fast}) async => DiscBufferPlan(speed:value,fast:fast,baseBytes:64*1024*1024,memoryMiB:32);
  Future<void> _setDiscPlan(DiscBufferPlan value) async { _appliedDiscPlan=value; }
  void _retainDiscCache() {}
  void _updatePersistentReadAhead() {}
  String get _cacheDescription=>'synthetic cache IO';
  _Log? log=_Log();
  _Disc? _disc;
  bool _disposed=false, _dolbyMapping=false;
  final _opening=false, _discInterrupted=false;
  bool _videoProbeBusy=false, _runtimeRepairBusy=false;
  final _hardwareRepairQueued=false, _positionRejected=false;
  int _runtimeEpoch=0, _seekIntent=0, _loadSerial=0, _videoSamples=0;
  int _nativeSeekSerial=0,_nativeRestartSeekSerial=0;
  bool _audioRefreshBroken=false;
  int? _discPtsLoad, _fastSeekIntent, _fastSeekNativeSerial;
  bool _discMissingVideoPts=false;
  Duration? _seekSince;
  String? _lastFailure;
  double _speed=1;
  final _discClockFault=DiscClockRecoveryEvidence(); int _playIntent=0;
final _videoLoss=VideoOutputLossWatch(); final _hdr=(changing:false);
final _diagnosticBudget=DiagnosticBudget();
Future<void> _recordDiagnosticContext(NativePlayer native) async {}
void expectVideo() => _videoLoss.reset(expectedVideo:true);

  Future<void> Function()? beforeBuffer;
  List<String> get logs=>log!.rows;
  String? get failure=>_lastFailure;
  bool get recovering=>_runtimeWatch.recovering;
  bool get attempted=>_runtimeWatch.attempted;
  void _failPlayback(String message) { _lastFailure??=message; }
  void _armBufferPhase() {}
  void _cancelBufferPhase() {}
  Future<void> _beginFastBuffer(String reason) async { await beforeBuffer?.call(); }
  Future<void> _repairHardwareFallback(NativePlayer native, HardwareRepairAction action) async { throw StateError('unexpected hardware failure'); }
  void start({int serial=1, bool disc=true, bool dolby=false, double speed=1}) {
    _loadSerial=serial; _runtimeEpoch++; _runtimeWatch.reset();
    _disc=disc?_Disc(Object()):null; _dolbyMapping=dolby; _speed=speed;
    _lastFailure=null; _runtimePosition.reset(Duration.zero);
    _beginDiscTimestampScope(serial);
  }
  void checkpoint(double value) => _runtimePosition.reset(Duration(microseconds:(value*1e6).round()));
  // Native position-stream IO at the accepted seek target, before a later
  // periodic health probe. Use the actual production guard, not a fake clock.
  void seekEvent() { _nativeSeekSerial++; }
  void restartEvent() { _nativeRestartSeekSerial=_nativeSeekSerial; }
  void positionEvent(double value) {
    player.state.position=Duration(microseconds:(value*1e6).round());
    _runtimePosition.accept(player.state.position,duration:player.state.duration);
    if(!_runtimePosition.settling) _seekSince=null;
  }
  void packet(String p,String l,String t) => _observeDiscPacketTimestamp(p,l,t);
  void disposeNow() { _disposed=true; }
  Future<void> repair(String hardware) => _repairRuntimeVideo(native,hardware);
  Future<void> confirmRate(double value,int ms) { _runtimeClock.elapsed=Duration(milliseconds:ms); return _applyRate(value); }
  Future<void> blockQueue(Future<void> release) => _rates.run(() => release);
  void setPlaying(bool value) { player.state.playing=value; }
  void setBuffering(bool value) { player.state.buffering=value; }
  Future<void> probeAt(int ms,double video,double? audio, {
    bool buffering=false, bool playing=true, bool seeking=false, bool ready=true,
    String hardware='mediacodec-copy',
    String? nativePosition,
  }) async {
    _runtimeClock.elapsed=Duration(milliseconds:ms);
    player.state.position=Duration(microseconds:(video*1e6).round());
    player.state.playing=playing; player.state.buffering=buffering;
    native.values.addAll({
      'current-vo':'gpu', 'vo-configured':ready?'yes':'no', 'hwdec-current':hardware,
      'video-frame-info/interlaced':ready?'no':'unavailable',
      'time-pos':nativePosition??'$video', 'audio-pts':audio==null?'unavailable':'$audio',
      'seeking':seeking?'yes':'no', 'paused-for-cache':buffering?'yes':'no',
    });
    await _recordVideoHealth();
    await Future<void>.delayed(Duration.zero);
  }
  Future<void> _recordVideoHealth() async {
    if (_hdr.changing) return;
    final native = player.platform;
    if (_disposed ||
        _diagnosticBudget.stopped ||
        _videoProbeBusy ||
        native is! NativePlayer) {
      return;
    }
    _videoProbeBusy = true;
    final epoch = _runtimeEpoch;
    final load = _loadSerial;
    final intent = _seekIntent;
    final dolbyGeneration = _dolbyRecovery.generation;
    final sampleGeneration = _observation.generation;
    final sampleSpeed = _speed;
    try {
      final fields = <String>[];
      final values = <String, String>{};
      for (final key in [
        'current-vo',
        'vo-configured',
        'hwdec-current',
        'video-frame-info/interlaced',
        'video-out-params/pixelformat',
        'video-dec-params/pixelformat',
        'estimated-frame-number',
        'decoder-frame-drop-count',
        'frame-drop-count',
        'time-pos',
        'audio-pts',
        'avsync',
        'speed',
        'seeking',
        'paused-for-cache',
        'demuxer-cache-duration',
      ]) {
        if (_disposed || _diagnosticBudget.stopped) return;
        try {
          final value = await native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600));
          values[key] = value;
          fields.add(
            '$key=${RegExp(r'^[a-zA-Z0-9_.-]{1,40}$').hasMatch(value) ? value : "未提供"}',
          );
        } catch (_) {
          fields.add('$key=未提供');
        }
      }

      if (_disposed ||
          _diagnosticBudget.stopped ||
          _lastFailure != null ||
          _hdr.changing ||
          epoch != _runtimeEpoch ||
          load != _loadSerial ||
          intent != _seekIntent ||
          sampleGeneration != _observation.generation) {
        return;
      }
      final now = _runtimeClock.elapsed;
      if (!_runtimeRepairBusy) {
        _runtimePosition.accept(
          player.state.position,
          duration: player.state.duration,
        );
        if (!_runtimePosition.settling) _seekSince = null;
      }
      if (!player.state.playing && _seekSince != null) _seekSince = now;
      if (_seekSince != null &&
          !_dolbyRecovery.trackingSeek &&
          now - _seekSince! > const Duration(seconds: 30)) {
        _failPlayback('定位超过 30 秒仍未得到目标位置，已保留定位进度');
        return;
      }
      final nativePosition = mediaClock(values['time-pos']);
      final sample = RuntimeSample(
        now: now,
        position: nativePosition ?? player.state.position,
        audioPosition: mediaClock(values['audio-pts']),
        playing: player.state.playing,
        buffering: player.state.buffering,
        seeking: values['seeking'] != 'no' || _runtimePosition.settling,
        cachePaused: values['paused-for-cache'] != 'no',
        outputReady:
            values['vo-configured'] == 'yes' &&
            const {
              'yes',
              'no',
            }.contains(values['video-frame-info/interlaced']) &&
            values['current-vo'] != null &&
            values['current-vo'] != 'null',
        hardware: values['hwdec-current'] ?? '',
      );
      if (_videoLoss.sample(
        sample,
        outputMissing: values['vo-configured'] == 'no',
      )) {
        _failPlayback('画面输出已丢失，声音仍在前进；已停止播放并保留观看进度');
        return;
      }
      _discClockFault.observe(
        sample,
        load: load,
        epoch: epoch,
        intent: intent,
        selectedOrdinaryDisc:
            nativePosition != null && _disc?.selected != null && !_dolbyMapping,
      );
      final dolbyAction = _dolbyRecovery.sample(
        sample,
        generation: dolbyGeneration,
        speed: _speed,
      );
      if (dolbyAction == DolbyRecoveryAction.fail) {
        _failPlayback('杜比定位恢复后未得到目标位置的连续音画，已保留观看进度');
        return;
      } else if (dolbyAction == DolbyRecoveryAction.recovered) {
        log?.add(LogArea.player, '杜比定位恢复已核对：新播放重启后目标位置的音画时钟连续前进；不代表已验证颜色');
      }
      if (_fastSeekIntent != null &&
          _fastSeekNativeSerial != null &&
          _nativeRestartSeekSerial > _fastSeekNativeSerial! &&
          _nativeRestartSeekSerial == _nativeSeekSerial &&
          !sample.seeking &&
          sample.outputReady) {
        final intent = _fastSeekIntent;
        await _rates.run(() async {
          if (_disposed || intent != _seekIntent || intent != _fastSeekIntent) {
            return;
          }
          try {
            await _startupSeek.restore(
              read: (key) => native
                  .getProperty(key)
                  .timeout(const Duration(milliseconds: 600)),
              write: (key, value) => native
                  .setProperty(key, value)
                  .timeout(const Duration(seconds: 2)),
            );
          } catch (_) {
            _failPlayback('精确定位参数未能恢复，已保留观看进度');
          }
          _fastSeekIntent = null;
          _fastSeekNativeSerial = null;
        });
        if (_disposed || _lastFailure != null || epoch != _runtimeEpoch) return;
      }
      final hardwareAction =
          _runtimeRepairBusy ||
              _hardwareRepairQueued ||
              _dolbyRecovery.recovering
          ? HardwareRepairAction.none
          : _hardwareFallback.sample(sample);
      if (hardwareAction == HardwareRepairAction.retryHardware ||
          hardwareAction == HardwareRepairAction.cleanSoftware) {
        unawaited(_repairHardwareFallback(native, hardwareAction));
      } else if (hardwareAction == HardwareRepairAction.verified) {
        log?.add(
          LogArea.player,
          '解码重建后时钟核对通过：实际解码=${sample.hardware}；'
          '音频与视频时钟已前进；不代表已验证画面无花屏或设备全倍速流畅',
        );
      }
      final action =
          _runtimeRepairBusy ||
              _hardwareRepairQueued ||
              _dolbyRecovery.recovering
          ? RuntimeAction.none
          : _runtimeWatch.sample(sample, speed: _speed);
      if (action == RuntimeAction.recover) {
        unawaited(_repairRuntimeVideo(native, sample.hardware));
      } else if (action == RuntimeAction.recovered) {
        log?.add(
          LogArea.player,
          '视频恢复核对通过：当前媒体内音频与视频时钟已连续前进；实际解码=${sample.hardware}；倍速=$_speed',
        );
      } else if (action == RuntimeAction.fail) {
        _failPlayback(
          '视频时钟持续停滞，音频仍在前进；${_runtimeWatch.attempted ? "本次恢复未成功" : "没有可用的硬解恢复条件"}，已保留最后有效进度',
        );
      }
      // Resolve video recovery first: its sixth-second decision can coincide
      // with the audio fault deadline in this same sample.
      final audioAction = _audioDecode.sample(
        sample,
        videoRecovering:
            _runtimeWatch.recovering ||
            _runtimeRepairBusy ||
            _dolbyRecovery.recovering ||
            dolbyAction == DolbyRecoveryAction.recovered ||
            action == RuntimeAction.recovered,
      );
      if (audioAction == AudioDecodeAction.fail) {
        _failPlayback('音频解码错误后未恢复连续音画输出，已保留观看进度');
        return;
      } else if (audioAction == AudioDecodeAction.verified) {
        log?.add(LogArea.player, '音频包错误后核对：视频与音频时钟均已前进，保留原音轨播放');
      }
      final recordDiagnostic = _diagnosticBudget.allow(
        'video',
        now,
        enabled: log?.enabled == true,
        playing: player.state.playing && !player.state.completed,
        abnormal:
            action != RuntimeAction.none ||
            sample.seeking ||
            sample.cachePaused ||
            _positionRejected,
      );
      if (recordDiagnostic) {
        values.addAll(await readPlaybackCache(native.getProperty));
      }
      if (_disposed ||
          _diagnosticBudget.stopped ||
          epoch != _runtimeEpoch ||
          load != _loadSerial ||
          intent != _seekIntent ||
          sampleGeneration != _observation.generation) {
        return;
      }
      final sampleAccepted = _observation.record(
        sampleGeneration: sampleGeneration,
        now: now,
        speed: sampleSpeed,
        values: values,
      );
      if (!recordDiagnostic) return;
      unawaited(_recordDiagnosticContext(native));
      if (log?.enabled == true) {
        final render = await readRenderMetrics(
          read: native.getProperty,
          active: () =>
              !_disposed &&
              !_diagnosticBudget.stopped &&
              _lastFailure == null &&
              !_hdr.changing &&
              epoch == _runtimeEpoch &&
              load == _loadSerial &&
              intent == _seekIntent &&
              sampleGeneration == _observation.generation,
        );
        if (render == null) return;
        fields.add(render);
      }
      log?.add(
        LogArea.player,
        '画面链路采样：${[fields[0], fields[2], fields[4]].join("；")}；'
        '${sampleAccepted ? _observation.describe(now) : "诊断采样跨越操作边界，不做区间比较"}；'
        '${fields.last}',
      );
    } finally {
      _videoProbeBusy = false;
    }
  }

  void _beginDiscTimestampScope(int serial) {
    _discClockFault.begin(
      load: serial,
      epoch: _runtimeEpoch,
      intent: _seekIntent,
    );
    _discMissingVideoPts = false;
    // Native log messages have no load serial. A reused player's old queue
    // cannot safely qualify a later media, even after clearing this flag.
    _discPtsLoad = serial == 1 && _disc?.selected != null ? serial : null;
  }

  void _observeDiscPacketTimestamp(String prefix, String level, String text) {
    if (_discPtsLoad != _loadSerial ||
        _disc?.selected == null ||
        _dolbyMapping ||
        prefix != 'ffmpeg/video' ||
        !const {'warn', 'error', 'fatal'}.contains(level)) {
      return;
    }
    if (RegExp(
      r'^(?:(?:hevc|h264|vp8|vp9|av1|mpeg2)_mediacodec: )?Input packet is missing PTS$',
    ).hasMatch(text.trim())) {
      _discMissingVideoPts = true;
    }
  }

  Future<void> _repairRuntimeVideo(NativePlayer native, String hardware) async {
    if (_disposed || _opening || _runtimeRepairBusy || _lastFailure != null) {
      return;
    }
    final epoch = _runtimeEpoch;
    final load = _loadSerial;
    final intent = _seekIntent;
    final requestedClockFallback =
        _disc?.selected != null &&
        !_dolbyMapping &&
        _discClockFault.qualifies(
          load: load,
          epoch: epoch,
          intent: intent,
          now: _runtimeClock.elapsed,
          hardware: hardware,
        );
    _hardwareFallback.cancel();
    _runtimeRepairBusy = true;
    bool active() =>
        !_disposed &&
        !_opening &&
        !_discInterrupted &&
        epoch == _runtimeEpoch &&
        load == _loadSerial &&
        intent == _seekIntent &&
        _lastFailure == null;
    try {
      await _rates.run(() async {
        if (!active()) return;
        if (requestedClockFallback &&
            (!player.state.playing ||
                player.state.buffering ||
                _runtimePosition.settling ||
                !_discClockFault.qualifies(
                  load: load,
                  epoch: epoch,
                  intent: intent,
                  now: _runtimeClock.elapsed,
                  hardware: hardware,
                ))) {
          return;
        }
        final target = _runtimePosition.value;
        // The fixed MediaCodec path substitutes zero for missing input PTS.
        // A current-load warning or independently observed clock regression
        // qualifies the disc's existing single recovery for software decoding.
        final missingPtsFallback =
            _discPtsLoad == _loadSerial &&
            _discMissingVideoPts &&
            _disc?.selected != null &&
            !_dolbyMapping &&
            const {'mediacodec', 'mediacodec-copy'}.contains(hardware);
        final clockRegressionFallback =
            _disc?.selected != null &&
            !_dolbyMapping &&
            _discClockFault.qualifies(
              load: load,
              epoch: epoch,
              intent: intent,
              now: _runtimeClock.elapsed,
              hardware: hardware,
            );
        final discSoftwareFallback =
            missingPtsFallback || clockRegressionFallback;
        // Acceleration alone is not evidence that software decode can sustain
        // this resource. Preserve the selected hardware for its one rebuild;
        // the independently verified disc timestamp fallback remains intact.
        final expected = discSoftwareFallback ? 'no' : hardware;
        _runtimeWatch.beginRecovery(
          target,
          _runtimeClock.elapsed,
          hardware: expected,
          requireSynchronizedAv: true,
          speed: _speed,
        );
        _discClockFault.clear();
        log?.add(
          LogArea.player,
          '视频停滞恢复开始：音频前进、视频至少 6 秒未前进；'
          '保留=${target.inMilliseconds} ms；倍速=$_speed；'
          '仅一次${expected == "no" ? "后备解码" : "原硬解重建"}，不重新打开入口'
          '${clockRegressionFallback
              ? "；本次原盘同步输出后无定位持续回零，避免重复同一路硬解"
              : missingPtsFallback
              ? "；本次原盘已记录缺失 PTS，避免重复同一路硬解"
              : ""}',
          level: LogLevel.warning,
        );
        await _beginFastBuffer('视频停滞恢复');
        if (!active()) return;
        await native
            .setProperty('hwdec', expected)
            .timeout(const Duration(seconds: 3));
        if (!active()) return;
        _observation.invalidate();
        _runtimePosition.beginSeek(target);
        _seekSince = _runtimeClock.elapsed;
        _cachedTransport?.seek();
        _disc?.resetReadAhead();
        _armBufferPhase();
        await player.seek(target).timeout(const Duration(seconds: 3));
        if (!active()) return;
        log?.add(LogArea.player, '视频恢复命令已完成；等待音画时钟前进核对，最多 30 秒播放时间');
      });
    } catch (_) {
      if (active()) {
        _failPlayback('视频停滞后的解码恢复命令失败，已保留最后有效进度');
      }
    } finally {
      _runtimeRepairBusy = false;
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

  Future<void> _applyRate(double value) async {
    if (_disposed) return;
    if (!value.isFinite || value < .5 || value > 3) {
      throw const AppFailure('播放倍速超出支持范围');
    }
    if (value == _speed) {
      _retainDiscCache();
      return;
    }
    if (_disc != null) _readAhead.speed(value);
    _rateProbe.cancel();
    final previousSpeed = _speed;
    _observation.invalidate();
    final previous = _appliedDiscPlan;
    final previousStream = _streamBuffer.snapshot;
    try {
      if (_disc == null && _networkFile) {
        await _streamBuffer.configure(value, fast: _bufferPhase.fast);
      } else {
        // Returning to a lower actual speed does not shrink warm prefetch here.
        // Only its resume gate follows the actual speed, without a memory query.
        final plan =
            previous != null &&
                !previous.fast &&
                !_bufferPhase.fast &&
                previous.tier >= discBufferTier(value)
            ? previous.withPlaybackSpeed(value)
            : await _discPlan(value, fast: _bufferPhase.fast);
        await _setDiscPlan(plan);
      }
      if (_disposed) return;
      await player.setRate(value);
    } catch (_) {
      _observation.invalidate();
      if (!_disposed && _disc == null && _networkFile) {
        try {
          await _streamBuffer.restoreSnapshot(previousStream);
        } catch (_) {
          _failPlayback('倍速设置失败后的缓存参数恢复未完成');
        }
      }
      if (!_disposed && previous != null) {
        try {
          await _setDiscPlan(previous);
        } catch (_) {
          log?.add(
            LogArea.player,
            '倍速设置失败后的缓冲参数恢复未完成',
            level: LogLevel.warning,
          );
        }
      }
      _retainDiscCache();
      rethrow;
    }
    _speed = value;
    _dolbyRecovery.observeSpeed(value);
    _runtimeWatch.observeSpeed(value);
    _readAhead.speed(value, retainPeak: _disc != null);
    _updatePersistentReadAhead();
    _retainDiscCache();
    _observation.invalidate();
    if (_bufferPhase.promotionFailed) {
      _bufferPhase.promotionFailed = false;
      _armBufferPhase();
    }
    _bufferWatch.reset();
    log?.add(LogArea.player, '播放倍速已设置：$value；$_cacheDescription');
    _rateProbe.start(previousSpeed, value);
  }
}
