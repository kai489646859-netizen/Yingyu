// Complete production recovery methods; native/player and logging IO only are substitutes.
// ignore_for_file: library_private_types_in_public_api
import 'dart:async';
import 'package:yingyu/playback/disc_buffering.dart';
import 'package:yingyu/playback/hardware_fallback.dart';
import 'package:yingyu/playback/position_guard.dart';
import 'package:yingyu/playback/runtime_health.dart';
import 'package:yingyu/playback/disc_clock_recovery.dart';

enum LogArea { player }
enum LogLevel { warning }
class _Log {
  final rows = <String>[];
  void add(LogArea area, String text, {LogLevel? level}) => rows.add(text);
}
class NativePlayer {
  final writes = <(String, String)>[];
  Future<void> Function()? beforeWrite;
  bool failWrite = false;
  Future<void> setProperty(String key, String value) async {
    writes.add((key, value));
    await beforeWrite?.call();
    if (failWrite) throw StateError('synthetic property failure');
  }
}
class _State { bool playing = true, buffering = false; }
class _Player {
  final state = _State();
  final seeks = <Duration>[];
  Future<void> seek(Duration target) async => seeks.add(target);
}
class _Clock { Duration elapsed = Duration.zero; }
class _Observation { int invalidations = 0; void invalidate() => invalidations++; }
class _Cache { int seeks = 0; void seek() => seeks++; }
class _Disc {
  _Disc(this.selected);
  Object? selected;
  int resets = 0;
  void resetReadAhead() => resets++;
}

abstract class BackendHarness {
  final native = NativePlayer();
  final player = _Player();
  final _runtimeClock = _Clock();
  final _runtimePosition = PlaybackPositionGuard();
  final _runtimeWatch = RuntimeHealthWatch();
  final _discClockFault = DiscClockRecoveryEvidence();
  final _hardwareFallback = HardwareFallbackWatch();
  final _observation = _Observation();
  final _cache = _Cache();
  _Cache? get _cachedTransport => _cache;
  _Log? log = _Log();
  late final _rates = PlaybackRateQueue((_) async {});
  _Disc? _disc;
  bool _disposed = false, _runtimeRepairBusy = false;
  final _opening = false, _discInterrupted = false;
  bool _dolbyMapping = false;
  int _runtimeEpoch = 0, _seekIntent = 0, _loadSerial = 0;
  int? _discPtsLoad;
  bool _discMissingVideoPts = false;
  String? _lastFailure;
  Duration? _seekSince;
  double _speed = 1;
  Future<void> Function()? beforeBuffer;
  int fastBuffers = 0, armed = 0, emits = 0;
  String? get failure => _lastFailure;
  bool get recovering => _runtimeWatch.recovering;
  bool get attempted => _runtimeWatch.attempted;
  Duration? get seekSince => _seekSince;
  List<String> get logs => log!.rows;
  void _failPlayback(String message) => _lastFailure ??= message;
  void _armBufferPhase() => armed++;
  void emit() => emits++;
  Future<void> _beginFastBuffer(String reason) async {
    fastBuffers++;
    await beforeBuffer?.call();
  }
  void start({int serial = 1, bool disc = true, bool selected = true,
      bool dolby = false, double speed = 1}) {
    _loadSerial = serial;
    _disc = disc ? _Disc(selected ? Object() : null) : null;
    _dolbyMapping = dolby;
    _speed = speed;
    _runtimePosition.reset(const Duration(seconds: 6));
    beginScope(serial);
  }
  void selectTimeline() => _disc!.selected = Object();
  void manualSeek(int seconds) {
    _seekIntent++;
    _runtimeEpoch++;
    _runtimeWatch.seek();
    _runtimePosition.reset(Duration(seconds: seconds));
  }
  void disposeNow() => _disposed = true;
  RuntimeAction sample({required int now, required int position,
      int? audio, String hardware = 'no', bool ready = true}) =>
      _runtimeWatch.sample(RuntimeSample(
        now: Duration(seconds: now), position: Duration(seconds: position),
        audioPosition: audio == null ? null : Duration(seconds: audio),
        playing: true, buffering: false, seeking: false, cachePaused: false,
        outputReady: ready, hardware: hardware), speed: _speed);
  void beginScope(int serial);
  void packet(String prefix, String level, String text);
  Future<void> repair(String hardware);
}

class OldBackendHarness extends BackendHarness {
  @override void beginScope(int serial) {}
  @override void packet(String p, String l, String t) {}
  Future<void> _repairRuntimeVideo(NativePlayer native, String hardware) async {
    if (_disposed || _opening || _runtimeRepairBusy || _lastFailure != null) {
      return;
    }
    final epoch = _runtimeEpoch;
    final intent = _seekIntent;
    _hardwareFallback.cancel();
    _runtimeRepairBusy = true;
    bool active() =>
        !_disposed &&
        !_opening &&
        !_discInterrupted &&
        epoch == _runtimeEpoch &&
        intent == _seekIntent &&
        _lastFailure == null;
    try {
      await _rates.run(() async {
        if (!active()) return;
        final target = _runtimePosition.value;
        // Keep the established >2x fallback. At normal/2x speed rebuild the
        // observed hardware decoder instead of forcing 4K software decoding.
        final expected = _speed > 2 ? 'no' : hardware;
        _runtimeWatch.beginRecovery(
          target,
          _runtimeClock.elapsed,
          hardware: expected,
        );
        log?.add(
          LogArea.player,
          '视频停滞恢复开始：音频前进、视频至少 6 秒未前进；'
          '保留=${target.inMilliseconds} ms；倍速=$_speed；'
          '仅一次${expected == "no" ? "后备解码" : "原硬解重建"}，不重新打开入口',
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
  @override Future<void> repair(String hardware) => _repairRuntimeVideo(native, hardware);
}

class CurrentBackendHarness extends BackendHarness {
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
  @override void beginScope(int serial) => _beginDiscTimestampScope(serial);
  @override void packet(String p, String l, String t) => _observeDiscPacketTimestamp(p, l, t);
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
  @override Future<void> repair(String hardware) => _repairRuntimeVideo(native, hardware);
}
