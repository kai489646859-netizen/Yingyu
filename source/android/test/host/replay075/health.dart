import 'package:yingyu/playback/render_metrics.dart';
import 'package:yingyu/playback/diagnostic_budget.dart';
// Generated production methods. Native property/repair IO is substituted.
// ignore_for_file: library_private_types_in_public_api, unused_field
import 'dart:async';
import 'package:yingyu/playback/observation.dart' show readPlaybackCache;
import 'package:yingyu/playback/audio_decode_watch.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'package:yingyu/playback/position_guard.dart';
import 'package:yingyu/playback/hardware_fallback.dart';
import 'package:yingyu/playback/dolby_recovery.dart';
import 'package:yingyu/playback/startup_seek.dart';
import 'package:yingyu/playback/disc_clock_recovery.dart';
import 'audio_old.dart' as old_audio;
class NativePlayer {
 final values=<String,String>{};
 Future<String> getProperty(String k) async => values[k]??'unavailable';
 Future<void> setProperty(String k,String v) async {values[k]=v;}
}
class _State {
 Duration position=Duration.zero,duration=const Duration(seconds:8246);
 bool playing=true,buffering=false,completed=false; int? width=3840,height=2160;
}
class _Player { Object platform=NativePlayer(); final state=_State(); }
class _Clock { Duration elapsed=Duration.zero; }
class _Cell<T> { T value; _Cell(this.value); }
class _Rect { double width=3840,height=2160; }
class _Video { final rect=_Cell<_Rect?>(_Rect()),id=_Cell<int?>(1); }
class _Observation {
 int generation=0;
 bool record({required int sampleGeneration,required Duration now,required double speed,required Map<String,String> values})=>true;
 String describe(Duration now)=>'';
}
class _Rates {Future<void> run(Future<void> Function() f)=>f();}
class _Disc { Object? selected; }
abstract class HealthHarness {
 HealthHarness({bool previous=false}) { _audioDecode=previous?old_audio.AudioDecodeWatch():AudioDecodeWatch(); }
 final _disposed=false,_hardwareRepairQueued=false,_positionRejected=false;
 bool _videoProbeBusy=false,_runtimeRepairBusy=false;
 final _runtimeEpoch=0,_seekIntent=0;
 final _loadSerial=1,_dolbyMapping=false;
 final _Disc? _disc=null;
 final _discClockFault=DiscClockRecoveryEvidence();
 int _videoSamples=0;
 final int _nativeSeekSerial=0, _nativeRestartSeekSerial=0;
 int? _fastSeekNativeSerial;
 int? _fastSeekIntent;Duration? _seekSince;String? _lastFailure;
 final double _speed=1;
 final player=_Player(),video=_Video(),_runtimeClock=_Clock(),_observation=_Observation(),_rates=_Rates();
 final _runtimePosition=PlaybackPositionGuard(),_runtimeWatch=RuntimeHealthWatch();
 late final dynamic _audioDecode;
 final _hardwareFallback=HardwareFallbackWatch(),_startupSeek=StartupSeekSetup();
 final _dolbyRecovery=DolbySeekRecovery();
 final _Log? log=null;
 int repairs=0;
 String? get failure=>_lastFailure;
 bool get recovering=>_runtimeWatch.recovering;
 bool get pendingAudio=>_audioDecode.pending;
 void fault(int second,{int count=1}) {for(var n=0;n<count;n++){_audioDecode.fault(Duration(seconds:second),playing:true);}}
 Future<void> sampleAt(int second,double position,double audio,{bool buffering=false,bool playing=true,bool seek=false}) async {
   _runtimeClock.elapsed=Duration(seconds:second);
   player.state.position=Duration(microseconds:(position*1e6).round());
   player.state.playing=playing;player.state.buffering=buffering;
   (player.platform as NativePlayer).values.addAll({
     'current-vo':'gpu','vo-configured':'yes','hwdec-current':'mediacodec-copy',
     'video-frame-info/interlaced':'no','time-pos':'$position','audio-pts':'$audio',
     'seeking':seek?'yes':'no','paused-for-cache':buffering?'yes':'no'});
   await probe();
 }
 Future<void> probe();
 void _failPlayback(String message) {_lastFailure??=message;}
 Future<void> _repairRuntimeVideo(NativePlayer n,String hardware) async {
   _runtimeRepairBusy=true;repairs++;
   _runtimeWatch.beginRecovery(const Duration(seconds:13),_runtimeClock.elapsed,hardware:hardware);
   await Future<void>.value();_runtimeRepairBusy=false;
 }
 Future<void> _repairHardwareFallback(NativePlayer n,HardwareRepairAction action) async {throw StateError('unexpected hardware transition');}
}
enum LogArea {player}
class _Log { bool get enabled => true; void add(LogArea area,String message) {} }

class OldHealth extends HealthHarness {
 OldHealth():super(previous: true);

  Future<void> _recordVideoHealth() async {
    final native = player.platform;
    if (_disposed || _videoProbeBusy || native is! NativePlayer) {
      return;
    }
    _videoProbeBusy = true;
    final epoch = _runtimeEpoch;
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
        if (_disposed) return;
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
      if (_disposed || _lastFailure != null || epoch != _runtimeEpoch) return;
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
          now - _seekSince! > const Duration(seconds: 30)) {
        _failPlayback('定位超过 30 秒仍未得到目标位置，已保留定位进度');
        return;
      }
      final sample = RuntimeSample(
        now: now,
        position: mediaClock(values['time-pos']) ?? player.state.position,
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
      final audioAction = _audioDecode.sample(
        sample,
        videoRecovering: _runtimeWatch.recovering || _runtimeRepairBusy,
      );
      if (_fastSeekIntent != null && !sample.seeking && sample.outputReady) {
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
        });
        if (_disposed || _lastFailure != null || epoch != _runtimeEpoch) return;
      }
      if (audioAction == old_audio.AudioDecodeAction.fail) {
        _failPlayback('音频解码错误后未恢复连续音画输出，已保留观看进度');
        return;
      } else if (audioAction == old_audio.AudioDecodeAction.verified) {
        log?.add(LogArea.player, '音频包错误后核对：视频与音频时钟均已前进，保留原音轨播放');
      }
      final hardwareAction = _runtimeRepairBusy || _hardwareRepairQueued
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
      final action = _runtimeRepairBusy || _hardwareRepairQueued
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
      final sampleAccepted = _observation.record(
        sampleGeneration: sampleGeneration,
        now: now,
        speed: sampleSpeed,
        values: values,
      );
      if (++_videoSamples % 5 != 1 &&
          action == RuntimeAction.none &&
          !_positionRejected) {
        return;
      }
      final rect = video.rect.value;
      log?.add(
        LogArea.player,
        '画面链路采样：纹理已分配=${video.id.value != null}；'
        '纹理尺寸=${rect?.width.toInt() ?? 0}×${rect?.height.toInt() ?? 0}；'
        '画面尺寸=${player.state.width ?? 0}×${player.state.height ?? 0}；'
        '位置=${player.state.position.inMilliseconds} ms；播放=${player.state.playing}；'
        '缓冲=${player.state.buffering}；${fields.join("；")}；'
        '${sampleAccepted ? _observation.describe(now) : "诊断采样跨越操作边界，不做区间比较"}',
      );
    } finally {
      _videoProbeBusy = false;
    }
  }


 @override Future<void> probe() => _recordVideoHealth();
}

class CurrentHealth extends HealthHarness {
 CurrentHealth():super(previous: false);
final _hdr=(changing:false);final _videoLoss=VideoOutputLossWatch(); final _diagnosticBudget=DiagnosticBudget(); Future<void> _recordDiagnosticContext(NativePlayer native) async {}
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


 @override Future<void> probe() => _recordVideoHealth();
}
