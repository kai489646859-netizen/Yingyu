import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:media_kit_video/media_kit_video.dart';
import '../core/models.dart';
import '../version.dart';
import '../core/log.dart';
import 'diagnostics.dart';
import 'diagnostic_budget.dart';
import 'resource_diagnostics.dart';
export 'diagnostic_budget.dart' show PlaybackDiagnosticLifecycle;
import 'audio_ducking.dart';
import 'audio_balance.dart';
import 'picture_brightness.dart';
import 'shadow_enhancement.dart';
import 'enhancement_output.dart';
export 'audio_ducking.dart' show PlaybackDuckingBackend;
import 'http_trace.dart';
import 'opening_logs.dart';
import 'latency_probe.dart';
import 'origin_transport.dart';
import 'disc_transport.dart';
import 'disc_worker.dart';
import 'disc_native.dart';
import 'dart:ffi' show Pointer, Void;
import 'disc_buffering.dart';
import 'rate_transition.dart';
import 'disc_startup.dart';
import 'disc_seek_index.dart';
import 'disc_timestamps.dart';
import 'packet_trace.dart';
import 'disc_buffer_phase.dart';
import 'disc_cache_retention.dart';
import 'tracks.dart';
import 'subtitle_files.dart';
import 'phone_fit.dart';
import 'screen_fit.dart';
import 'screen_subtitles.dart';
import 'media_notice.dart';
import 'dolby_source.dart';
import 'dolby_recovery.dart';
import 'decoder_recovery.dart';
import 'device.dart';
import 'position_guard.dart';
import 'runtime_health.dart';
import 'disc_clock_recovery.dart';
import 'observation.dart';
import 'opening_output.dart';
import 'opening_surface.dart';
import 'opening_subtitles.dart';
import 'opening_buffer.dart';
import 'stream_buffering.dart';
import 'display_diagnostics.dart';
import 'byte_cache.dart';
import 'cache_policy.dart';
import 'cached_transport.dart';
import 'hardware_fallback.dart';
import 'media_facts.dart';
import 'audio_decode_watch.dart';
import 'audio_track_switch.dart';
import 'audio_refresh.dart';
import 'pipeline_metrics.dart';
import 'initial_stream_buffer.dart';
import 'subtitle_switch.dart';
import 'startup_seek.dart';
import 'shader_cache.dart';
import 'render_metrics.dart';
import 'native_hdr.dart';
import 'playback_adjustments.dart';
export 'tracks.dart' show TrackOption;

class PlaybackSnapshot {
  const PlaybackSnapshot({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.openingStage = '正在打开媒体',
  });
  final Duration position, duration;
  final bool playing, buffering, completed;
  final String openingStage;
}

abstract class TrackStateBackend {
  String? get selectedAudioId;
  String? get selectedSubtitleId;
}

abstract class MediaNoticeBackend {
  String get sourceNotice;
}

abstract class OpeningTracksBackend {
  bool get prepareTracksWhilePaused;
  Future<void> settleOpeningTracks();
}

abstract class VideoGeometryBackend {
  double? get videoAspectRatio;
}

abstract class PlayerBackend {
  Stream<PlaybackSnapshot> get changes;
  Stream<String> get errors;
  PlaybackSnapshot get snapshot;
  List<TrackOption> get audioTracks;
  List<TrackOption> get subtitleTracks;
  Widget view(BoxFit fit);
  Future<void> open(PlaybackRoute route, Duration start);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> rate(double value);
  Future<void> audio(TrackOption track);
  Future<void> subtitle(TrackOption track);
  Future<void> dispose();
}

abstract class DiscNavigationBackend {
  List<DiscTitle> get discTitles;
  int? get selectedDiscPlaylist;
  set discPlaylist(int? value);
  set forcedDiscKind(DiscKind? value);
}

abstract class PersistentPlaybackBackend {
  void configureCache(PlaybackByteCache cache, String scope, Duration duration);
}

abstract class InitialSubtitleBackend {
  set openingSubtitleChoice(TrackOption? Function(List<TrackOption>)? choose);
}

class MpvBackend
    implements
        PlayerBackend,
        PlaybackDiagnosticLifecycle,
        InitialSubtitleBackend,
        DiscNavigationBackend,
        TrackStateBackend,
        VideoGeometryBackend,
        PlaybackDiagnosticState,
        PersistentPlaybackBackend,
        PlaybackFactsBackend,
        PlaybackResourceBackend,
        PlaybackChapterBackend,
        PictureBrightnessBackend,
        ShadowEnhancementBackend,
        SubtitleDelayBackend,
        SubtitlePositionBackend,
        DefaultSubtitlePositionBackend,
        InitialSubtitlePositionBackend,
        ScopedSubtitlePositionBackend,
        PlaybackDuckingBackend,
        AudioBalanceBackend,
        PlaybackOutputBackend,
        OpeningTracksBackend,
        MediaNoticeBackend {
  MpvBackend({
    int bufferBytes = 64 * 1024 * 1024,
    this.log,
    this.nativeHdr = false,
  }) {
    _baseBufferBytes = bufferBytes;
    _discCacheBytes = (bufferBytes >= 64 * 1024 * 1024 ? 32 : 16) * 1024 * 1024;
    player = Player(
      configuration: PlayerConfiguration(
        bufferSize: bufferBytes,
        logLevel: MPVLogLevel.warn,
      ),
    );
    video = VideoController(player);
    subscriptions.addAll([
      player.stream.log.listen((log) {
        if (_disposed || _discInterrupted || _diagnosticBudget.stopped) return;
        final stage = pipelineStageMessage(log.prefix, log.text);
        if (stage != null) {
          if (_diagnosticBudget.allow(
            DiagnosticBudget.nativeFamily(log.text),
            _runtimeClock.elapsed,
            enabled: this.log?.enabled == true,
            playing: _opening || player.state.playing,
          )) {
            this.log?.add(LogArea.player, stage);
          }
          return;
        }
        final workload = codecWorkloadMessage(log.prefix, log.text);
        if (workload != null) {
          this.log?.add(LogArea.player, workload);
          return;
        }
        if (_disc != null &&
            log.text.trim() ==
                'Yingyu CLPI indexed landing; exact decode retained.') {
          this.log?.add(LogArea.player, '原盘定位已使用 CLPI 访问点；继续精确解码到目标位置');
        }
        _observeDiscPacketTimestamp(log.prefix, log.level, log.text);
        final hdrStage = nativeHdrFailureStage(log.text);
        if (hdrStage != null) {
          if (_hdr.autoDolby &&
              (_hdr.autoArmed || _hdr.established) &&
              !_autoHdrRecovery.rejected) {
            final serial = _loadSerial;
            _decoderRecovery.outputChanged();
            unawaited(
              _autoHdrRecovery.reject(
                restore: _hdr.abandonAuto,
                current: () => !_disposed && serial == _loadSerial,
                restored: () {
                  this.log?.add(
                    LogArea.player,
                    '[HDR177] HDR10窗口拒绝=$hdrStage；已恢复当前杜比SDR映射',
                  );
                  emit();
                },
                failure: () => _failPlayback('杜比SDR输出恢复失败，已保留观看进度'),
              ),
            );
          }
          this.log?.add(
            LogArea.player,
            'HDR 原生窗口拒绝：$hdrStage',
            level: LogLevel.warning,
          );
        }
        _trace?.add(log.prefix, log.text);
        _latency?.add(log.prefix, log.text);
        _packetTrace?.add(log.prefix, log.level, log.text);
        if (_dolbyMapping) {
          final issue = classifyDolbyOutputFailure(
            log.prefix,
            log.level,
            log.text,
          );
          if (issue != DolbyOutputFailure.none) {
            unawaited(
              _handleDolbyOutputFailure(
                issue,
                dolbyOutputFailureCode(log.text),
              ),
            );
          }
        }
        if (_packetTrace?.exhausted == true) {
          unawaited(_stopPacketTrace());
        }
        if (!_opening &&
            _hardwareFallback.fault(log.prefix, log.level, log.text)) {
          unawaited(_recordVideoHealth());
        }
        if (enhancementRenderError(log.prefix, log.level, log.text)) {
          _enhancementRenderFault++;
        }
        if (_opening && _openingLogs?.enabled == true) {
          final openingReason = _openingVideoTrace.add(log.prefix, log.text);
          if (openingReason != null) {
            this.log?.add(LogArea.player, '开播原生原因：$openingReason');
          }
        }
        final videoWarning = _videoDiagnostics.add(
          log.prefix,
          log.level,
          log.text,
        );
        if (videoWarning != null) {
          this.log?.add(
            LogArea.player,
            '$videoWarning；位置=${player.state.position.inMilliseconds} ms；'
            '倍速=$_speed；开播=$_opening；$diagnosticState',
            level: LogLevel.warning,
          );
        }
        final changed = diagnostics.add(log.prefix, log.level, log.text);
        if (changed) {
          this.log?.add(
            LogArea.network,
            _describe('媒体请求失败'),
            level: LogLevel.error,
          );
        }
        if (changed && _lastFailure != null && !failures.isClosed) {
          failures.add(_describe(_lastFailure!));
        }
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
      }),
      player.stream.position.listen((_) => emit()),
      player.stream.duration.listen((_) => emit()),
      player.stream.videoParams.listen((_) => emit()),
      player.stream.playing.listen((playing) {
        _dolbyRecovery.playbackChanged(
          now: _runtimeClock.elapsed,
          playing: playing,
        );
        _disc?.setBuffering(playing && !_opening && player.state.buffering);
        emit();
      }),
      player.stream.buffering.listen((buffering) {
        if (buffering) _audioDecode.suspend();
        // Opening/paused initialization is not proof of network starvation.
        _disc?.setBuffering(buffering && !_opening && player.state.playing);
        _scheduleStarvationRecovery(buffering);
        emit();
      }),
      player.stream.completed.listen((_) => emit()),
      player.stream.tracks.listen((_) => _tracksChanged()),
      player.stream.track.listen((_) => _tracksChanged()),
    ]);
    final native = player.platform;
    if (native is NativePlayer) {
      subscriptions.add(native.playbackEvents.listen(_nativeEvent));
    }
  }
  late final Player player;
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

  late final _audioDucking = PlaybackDucking(
    read: () => player.state.volume,
    write: player.setVolume,
  );
  @override
  Future<void> setAudioDucked(bool value) => _audioDucking.set(value);
  late final VideoController video;
  bool _dolbyMapping = false;
  final _autoHdrRecovery = DolbyHdrRecovery();
  final bool nativeHdr;
  @override
  bool get prepareTracksWhilePaused =>
      _pendingHdrTransfer != null || (_hdr.established && !_hdr.autoDolby);

  String? _pendingHdrTransfer;
  @override
  Future<void> settleOpeningTracks() async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed || _hdr.autoDolby) return;
    final serial = _loadSerial, intent = _playIntent;
    final transfer = _pendingHdrTransfer;
    _pendingHdrTransfer = null;
    if (transfer != null && _lastFailure == null) {
      final attemptClock = Stopwatch()..start();
      try {
        if (await native.getProperty('pause') != 'yes' ||
            _disposed ||
            serial != _loadSerial ||
            intent != _playIntent) {
          return;
        }
        _setStage('正在校验 HDR 显示');
        _beginLatency('hdr_refill', player.state.position);
        final established = _dolbyMapping
            ? await _hdr.prepareDolby()
            : await _hdr.prepare(transfer);
        log?.add(
          LogArea.player,
          'HDR 输出事务：${_hdr.status}；${await video.nativeHdrStatus}',
        );
        if (!established) {
          log?.add(LogArea.player, '原生 HDR 条件未成立，继续兼容显示；本次不再尝试');
        }
        log?.add(
          LogArea.player,
          'HDR 输出协商完成：耗时=${attemptClock.elapsedMilliseconds} ms；已建立=${_hdr.established}；初始轨道已处理',
        );
      } catch (_) {
        log?.add(
          LogArea.player,
          'HDR 输出事务失败：${_hdr.status}；${await video.nativeHdrStatus}',
          level: LogLevel.warning,
        );
        _failPlayback('HDR 输出参数恢复失败，已保留观看进度');
        // errors is an asynchronous stream. Returning normally lets the session
        // mark itself ready and call play before that failure reaches it.
        throw const AppFailure('HDR 输出参数恢复失败，已保留观看进度');
      }
    }
    if (!_hdr.established ||
        _disposed ||
        _lastFailure != null ||
        serial != _loadSerial ||
        intent != _playIntent) {
      return;
    }
    final clock = Stopwatch()..start();
    _setStage('正在衔接播放缓存');
    final result = await settleOpeningBuffer(
      read: native.getProperty,
      active: () =>
          !_disposed &&
          _lastFailure == null &&
          serial == _loadSerial &&
          intent == _playIntent,
    );
    log?.add(
      LogArea.player,
      'HDR 初始轨道衔接：$result；等待=${clock.elapsedMilliseconds} ms；未重新打开媒体',
    );
    if (log?.enabled == true) {
      unawaited(
        displayDiagnostics(
          native.getProperty,
          active: () =>
              !_disposed &&
              !_diagnosticBudget.stopped &&
              serial == _loadSerial &&
              _lastFailure == null,
        ).then((values) {
          if (values.isNotEmpty) {
            log?.add(
              LogArea.player,
              'HDR 最终显示与缓存参数核对：${values.entries.map((e) => '${e.key}=${e.value}').join('；')}',
            );
          }
        }),
      );
    }
  }

  late final _hdr = NativeHdrAdapter(
    preloadedWrite:
        ({
          required token,
          required width,
          required height,
          required transfer,
          required fill,
        }) async {
          final accepted = await video.setPreloadedDolbyHdrSurface(
            token: token,
            width: width,
            height: height,
            transfer: transfer,
            fill: fill,
            position: '${_runtimePosition.value.inMicroseconds / 1000000}',
            peak: _reportedHdrPeak,
          );
          if (!accepted && token != 0) {
            log?.add(
              LogArea.player,
              '[HDR180] Dolby接入拒绝；${await video.nativeHdrStatus}',
            );
          }
          return accepted;
        },
    verifyPreloaded: video.confirmPreloadedDolbyHdr,
    write:
        ({
          required token,
          required width,
          required height,
          required transfer,
          required fill,
        }) {
          final load = _loadSerial, seek = _seekIntent;
          return video.setNativeHdrSurface(
            token: token,
            width: width,
            height: height,
            transfer: transfer,
            fill: fill,
            onProgress: (stage, detail) {
              if (_disposed ||
                  load != _loadSerial ||
                  seek != _seekIntent ||
                  _lastFailure != null) {
                return;
              }
              final label = hdrLoadingMessage(stage);
              if (label != null && label != _stage) _setStage(label);
              log?.add(
                LogArea.player,
                '[HDR111] $stage${detail.isEmpty ? "" : ";$detail"}',
              );
            },
          );
        },
    detach: video.detachNativeHdrSurface,
    active: () => !_disposed && _lastFailure == null,
    message: (value) {
      log?.add(LogArea.player, value);
      if (!_disposed) emit();
    },
    failure: (value) {
      if (!_disposed) _failPlayback(value);
    },
  );
  double get _reportedHdrPeak => _hdr.capabilities.maxLuminance;
  @override
  String get outputDescription => _dolbyMapping
      ? (_hdr.dolbyEstablished ? _hdr.dolbyHdrLabel : '杜比映射 SDR')
      : _hdr.established
      ? '${_noticeDecoded['video-params/gamma'] == 'hlg' ? 'HLG' : 'HDR10'} · 高动态范围'
      : const {'pq', 'hlg'}.contains(_noticeDecoded['video-params/gamma'])
      ? 'SDR · HDR 色彩适配'
      : 'SDR · 标准动态范围';
  @override
  OutputCapabilities get outputCapabilities => _hdr.capabilities;
  SubtitleViewConfiguration _subtitleViewConfiguration =
      const SubtitleViewConfiguration();
  bool _subtitleAutomatic = true, _pictureFill = false;
  final _shadow = ShadowEnhancement();
  final _audioBalance = AudioBalanceControl();
  @override
  AudioBalance get audioBalance => _audioBalance.value;
  @override
  Future<AudioBalance> setAudioBalance(
    AudioBalance value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final watch = Stopwatch()..start();
    log?.add(LogArea.player, '音量均衡请求：${audioBalance.label} → ${value.label}');
    try {
      final result = await _audioBalance.set(
        value,
        read: native.getProperty,
        write: native.setProperty,
        active: () =>
            allowed() && !_disposed && !_opening && serial == _loadSerial,
        event: (stage) => log?.add(
          LogArea.player,
          '音量均衡：$stage；经过=${watch.elapsedMilliseconds} ms',
        ),
      );
      log?.add(
        LogArea.player,
        '音量均衡已确认：${result.label}；耗时=${watch.elapsedMilliseconds} ms；仅处理已解码音频，未改变音轨、声道或视频输出',
      );
      return result;
    } catch (e) {
      log?.add(
        LogArea.player,
        '音量均衡失败：${safeError(e)}；已确认档位=${audioBalance.label}；耗时=${watch.elapsedMilliseconds} ms',
        level: LogLevel.warning,
      );
      rethrow;
    } finally {
      watch.stop();
    }
  }

  @override
  double get shadowEnhancement => _shadow.value;
  int _enhancementRenderFault = 0;
  @override
  Future<double> setShadowEnhancement(
    double value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final dolby =
        useDolbyEnhancement(_noticeDecoded, 'gpu-next') &&
        await native.getProperty('current-vo') == 'gpu-next';
    bool active() =>
        allowed() && !_disposed && !_opening && serial == _loadSerial;
    final confirmation = dolby
        ? DolbyEnhancementConfirmation(
            read: native.getProperty,
            active: active,
            renderFault: () => _enhancementRenderFault,
          )
        : null;
    final actual = await _shadow.set(
      value,
      read: native.getProperty,
      write: native.setProperty,
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
      dolbyInplace: dolby,
      p7Sdr: _noticeDecoded['dolby-vision-profile'] == '7',
      prepareConfirmation: confirmation?.prepare,
      confirm: confirmation?.confirm,
    );
    log?.add(LogArea.player, '暗部增强：$actual；仅当前影片；按实际输出色彩处理，未改变解码或HDR输出方式');
    return actual;
  }

  double? _subtitleDefaultPosition;
  double? _initialSubtitlePosition;
  double? _regularSubtitlePosition, _discSubtitlePosition;
  bool _subtitleDiscEmbedded = false;
  int _subtitlePlacementGeneration = 0;
  @override
  SubtitlePositionScope get subtitlePositionScope => _subtitleDiscEmbedded
      ? SubtitlePositionScope.discEmbedded
      : SubtitlePositionScope.regular;
  @override
  void configureDiscSubtitlePosition(double? value) {
    if (_disposed || _opening || _loadSerial != 0) return;
    if (value != null && (!value.isFinite || value < 0 || value > 100)) {
      throw const AppFailure('字幕位置须在 0% 到 100% 之间');
    }
    _discSubtitlePosition = value;
  }

  void _selectSubtitlePlacement(bool discEmbedded) {
    _subtitleDiscEmbedded = discEmbedded;
    _subtitleDefaultPosition = null;
    final value = discEmbedded
        ? _discSubtitlePosition
        : _regularSubtitlePosition;
    _initialSubtitlePosition = value;
    _subtitleAutomatic = value == null;
    _subtitleViewConfiguration = SubtitleViewConfiguration(
      alignment: value == null
          ? Alignment.bottomCenter
          : Alignment(0, 1 - value / 50),
    );
  }

  @override
  void configureSubtitlePosition(double? value) {
    if (_disposed || _opening || _loadSerial != 0) return;
    if (value != null && (!value.isFinite || value < 0 || value > 100)) {
      throw const AppFailure('字幕位置须在 0% 到 100% 之间');
    }
    _initialSubtitlePosition = value;
    _regularSubtitlePosition = value;
    _subtitleAutomatic = value == null;
    _subtitleViewConfiguration = SubtitleViewConfiguration(
      alignment: value == null
          ? Alignment.bottomCenter
          : Alignment(0, 1 - value / 50),
    );
  }

  void _rememberSubtitleDefault(double position) {
    if (!_disposed &&
        _subtitleAutomatic &&
        player.state.subtitle.any((line) => line.trim().isNotEmpty)) {
      _subtitleDefaultPosition = position;
    }
  }

  @override
  bool get usesDefaultSubtitlePosition => _subtitleAutomatic;
  PhoneFit? _phoneFit;
  DateTime? _phonePlayingSince;
  bool get phoneViewport => _phoneFit != null;
  bool _screenCanvas = false;
  ScreenFit? _screenFit;
  Future<void> configureScreenViewport(int width, int height) async {
    if (_disposed || !await video.setScreenViewport(width, height)) return;
    _screenCanvas = true;
    final native = player.platform;
    if (native is! NativePlayer || _screenFit != null) return;
    _screenFit = ScreenFit(
      read: native.getProperty,
      write: native.setProperty,
      active: () => !_disposed,
    );
    await _screenFit!.set(false);
  }

  Future<void> resizeScreenViewport(int width, int height) async {
    if (!_disposed && _screenCanvas) {
      try {
        await video.setScreenViewport(width, height);
      } catch (_) {
        _failPlayback('画面尺寸更新失败，已保留观看进度');
        rethrow;
      }
    }
  }

  Future<void> configurePhoneViewport(int width, int height) async {
    if (_disposed ||
        _phoneFit != null ||
        !await video.setPhoneViewport(width, height)) {
      return;
    }
    final native = player.platform;
    if (native is! NativePlayer) return;
    final fit = PhoneFit(
      read: native.getProperty,
      write: native.setProperty,
      detect: () async {
        // Optional GPU/CPU frame readback must yield to actual playback.
        if (!await phoneFitReadbackAllowed(native.getProperty)) return null;
        final result = await native.detectLetterbox();
        final params = player.state.videoParams;
        if (result != null &&
            (result[0] != params.w || result[1] != params.h)) {
          return [params.w ?? 0, params.h ?? 0, 0];
        }
        return result;
      },
      healthy: () =>
          !_disposed &&
          !_opening &&
          _lastFailure == null &&
          player.state.playing &&
          !player.state.buffering &&
          !_runtimePosition.settling &&
          _speed == 1 &&
          _phonePlayingSince != null &&
          DateTime.now().difference(_phonePlayingSince!) >=
              const Duration(seconds: 6) &&
          (player.state.videoParams.aspect ?? 99) < width / height - .02 &&
          player.state.videoParams.w == player.state.videoParams.dw &&
          player.state.videoParams.h == player.state.videoParams.dh &&
          player.state.videoParams.rotate == 0 &&
          (player.state.width ?? 0) <= 4096 &&
          (player.state.height ?? 0) <= 2304,
      record: (message) => log?.add(LogArea.player, message),
      onRestoreFailure: () => _failPlayback('手机画面参数未能完整恢复，已停止播放并保留进度'),
      viewportAspect: width / height,
    );
    try {
      await fit.configure(fill: false);
      _phoneFit = fit;
      _screenCanvas = true;
    } catch (_) {
      fit.dispose();
      await video.setPhoneViewport(0, 0);
      if (_lastFailure != null) throw const AppFailure('手机画面参数未能完整恢复');
      log?.add(LogArea.player, '手机适应设置暂不可用，保留原画面布局');
    }
  }

  Future<void> setPhoneFill(bool fill) async {
    final serial = _loadSerial, generation = _subtitlePlacementGeneration;
    if (_phoneFit != null) {
      await _phoneFit!.configure(fill: fill);
    } else {
      await _screenFit?.set(fill);
    }
    final native = player.platform;
    if (!_disposed &&
        serial == _loadSerial &&
        generation == _subtitlePlacementGeneration &&
        _subtitleDiscEmbedded &&
        _subtitleAutomatic &&
        native is NativePlayer) {
      await writeMpvSubtitleLayout(
        scope: SubtitlePositionScope.discEmbedded,
        read: native.getProperty,
        write: native.setProperty,
        active: () =>
            !_disposed &&
            serial == _loadSerial &&
            generation == _subtitlePlacementGeneration,
      );
    }
    if (!_disposed) {
      _pictureFill = fill;
      emit();
    }
  }

  Future<void> Function()? _dolbyPreloadedHook;
  final updates = StreamController<PlaybackSnapshot>.broadcast();
  final failures = StreamController<String>.broadcast();
  final _diagnosticBudget = DiagnosticBudget();
  final _resourceObservation = ResourceObservation();
  bool _contextBusy = false;
  final diagnostics = PlaybackDiagnostics();
  final _videoDiagnostics = VideoDiagnostics();
  final _openingVideoTrace = OpeningVideoTrace();
  final _observation = PlaybackObservation();
  final _rateAudio = RateAudioSetup();
  PlaybackByteCache? _persistentCache;
  String _cacheScope = '';
  Duration _cacheDuration = Duration.zero;
  CachedPlaybackTransport? _cachedTransport;
  final _readAhead = PlaybackReadAhead();
  bool _readAheadAllowed = false;
  Map<String, String>? _discAppliedOptions;
  @override
  void configureCache(
    PlaybackByteCache cache,
    String scope,
    Duration duration,
  ) {
    _persistentCache = cache;
    _cacheScope = scope;
    _cacheDuration = duration;
  }

  final _discStartup = DiscStartupSetup();
  final _discSeekIndex = DiscSeekIndexSetup();
  final _discTimestamps = DiscTimestampSetup();
  final _discCache = DiscCacheSetup();
  final _discProbe = DiscProbeSetup();
  late final _rateProbe = RateSwitchProbe(
    read: (key) => (player.platform as NativePlayer).getProperty(key),
    record: (message) => log?.add(LogArea.player, message),
    active: () =>
        !_disposed && !_opening && _lastFailure == null && log?.enabled == true,
  );
  @override
  String get diagnosticState =>
      '$_cacheDescription；'
      '${_observation.describe(_runtimeClock.elapsed)}';
  bool _networkFile = false;
  bool get _usesBufferPolicy => _disc != null || _networkFile;
  String get _cacheDescription => _disc != null
      ? _discPlanDescription
      : _networkFile
      ? _streamBuffer.description
      : '普通媒体';
  late final _streamBuffer = StreamBuffering(
    baseBytes: _baseBufferBytes,
    memoryMiB: _baseBufferBytes ~/ (1024 * 1024),
    write: (key, value) async {
      if (_disposed) return;
      await (player.platform as NativePlayer).setProperty(key, value);
    },
    onRestoreFailure: () => _failPlayback('播放缓存参数调整失败，原参数也未能恢复'),
  );
  final _initialStreamBuffer = InitialStreamBuffer();
  Timer? _videoTimer;
  bool _videoProbeBusy = false;
  final _bufferPhase = DiscBufferPhase();
  DiscBufferPlan? _appliedDiscPlan;
  late final _discCacheRetention = DiscCacheRetention(
    (generation, tier) => unawaited(_releaseDiscCache(generation, tier)),
  );
  Timer? _bufferPhaseTimer;
  bool _bufferPhaseProbeBusy = false, _bufferPromotionQueued = false;
  final _runtimeWatch = RuntimeHealthWatch();
  final _videoLoss = VideoOutputLossWatch();
  final _discClockFault = DiscClockRecoveryEvidence();
  int? _discPtsLoad;
  bool _discMissingVideoPts = false;
  final _audioDecode = AudioDecodeWatch();
  final _startupSeek = StartupSeekSetup();
  final _openingSubtitleRead = OpeningSubtitleRead();
  @override
  set openingSubtitleChoice(TrackOption? Function(List<TrackOption>)? choose) =>
      _openingSubtitleChoice = choose;
  TrackOption? Function(List<TrackOption>)? _openingSubtitleChoice;
  TrackOption? Function(List<TrackOption>)? openingSecondaryChoice;
  String secondarySubtitleId = 'no';
  Future<void> _secondaryChanges = Future.value();
  Future<void> secondarySubtitle(TrackOption track) {
    final job = _secondaryChanges.then((_) => _setSecondarySubtitle(track));
    _secondaryChanges = job.catchError((Object _) {});
    return job;
  }

  Future<void> _setSecondarySubtitle(TrackOption track) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed || _opening) {
      throw const AppFailure('当前播放尚未就绪');
    }
    if (track.id != 'no' &&
        (track.control ||
            track.bitmap ||
            track.external ||
            int.tryParse(track.id) == null)) {
      throw const AppFailure('副字幕请选择内置文字轨道');
    }
    final load = _loadSerial;
    final previous = await native.getProperty('secondary-sid');
    if (_disposed || load != _loadSerial) return;
    if (track.id != 'no' && await native.getProperty('sid') == track.id) {
      throw const AppFailure('主副字幕不能选择同一轨道');
    }
    try {
      await native.setProperty('secondary-sid', track.id);
      if (_disposed || load != _loadSerial) return;
      if (await native.getProperty('secondary-sid') != track.id) {
        throw const AppFailure('副字幕切换未确认');
      }
      secondarySubtitleId = track.id;
    } catch (_) {
      if (!_disposed && load == _loadSerial) {
        await native.setProperty('secondary-sid', previous);
      }
      rethrow;
    }
  }

  int? _fastSeekIntent;
  final _hardwareFallback = HardwareFallbackWatch();
  final _dolbyRecovery = DolbySeekRecovery();
  bool _hardwareRepairQueued = false;
  final _runtimePosition = PlaybackPositionGuard();
  final _runtimeClock = Stopwatch()..start();
  int _runtimeEpoch = 0;
  int _seekIntent = 0;
  bool _runtimeRepairBusy = false, _positionRejected = false;
  Duration? _seekSince;
  final DiagnosticLog? log;
  final _trackMetadata =
      <String, ({int? pid, int? ffIndex, bool forced, bool external})>{};
  String? _decoderOpeningError;
  late final _decoderRecovery = DecoderRecovery(
    readOutput: _readVideoOutput,
    onFailure: _failPlayback,
    onRecovered: (state) => log?.add(
      LogArea.player,
      'MPV 解码恢复已核对：播放重启完成，视频输出持有帧；'
      '实际硬件解码=${state.hardwareDecoder}',
    ),
  );

  Future<VideoOutputState> _readVideoOutput() async {
    final native = player.platform;
    if (_disposed || native is! NativePlayer) {
      throw const AppFailure('播放会话已关闭');
    }
    final values = await Future.wait([
      for (final key in [
        'current-vo',
        'vo-configured',
        'video-frame-info/interlaced',
        'seeking',
        'hwdec-current',
      ])
        native.getProperty(key),
    ]).timeout(const Duration(seconds: 2));
    return VideoOutputState(
      output: values[0],
      configured: values[1] == 'yes',
      frameAvailable: const {'yes', 'no'}.contains(values[2]),
      seeking: values[3] != 'no',
      hardwareDecoder: values[4],
    );
  }

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

  void _failPlayback(String error) {
    _latency?.finish('playback_failed');
    _discClockFault.clear();
    unawaited(_stopPacketTrace());
    if (_disposed || _discInterrupted || _lastFailure != null) return;
    log?.add(
      LogArea.player,
      'MPV 报告播放错误：${_describe(error)}',
      level: LogLevel.error,
    );
    _lastFailure = error;
    _noticeReady = false;
    if (_opening) {
      if (_openFailure?.isCompleted == false) {
        _openFailure!.completeError(AppFailure(_describe(error)));
      }
    } else if (!failures.isClosed) {
      failures.add(_describe(error));
    }
    _decoderRecovery.cancel();
    _audioDecode.cancel();
    _dolbyRecovery.cancel();
    _cancelBufferPhase();
  }

  @override
  String get sourceNotice => !_noticeReady
      ? ''
      : _hdr.dolbyEstablished
      ? _hdr.dolbyHdrLabel
      : mediaNotice(
          bluray: _noticeBluray,
          streams: _noticeStreams,
          decoded: _noticeDecoded,
          nativeHdr: _hdr.established,
          dolbyMapped: _dolbyMapping,
          currentGamma: player.state.videoParams.gamma,
          currentMatrix: player.state.videoParams.colormatrix,
        );
  bool _noticeReady = false, _noticeBluray = false;
  List<Json> _noticeStreams = const [];
  Map<String, String> _noticeDecoded = const {};
  final _subtitleFiles = SubtitleFiles();
  final _subtitleFilePaths = <String>{};
  final _externalIds = <String, String>{};
  bool _tracksReady = false, _tracksBusy = false, _tracksDirty = false;
  @override
  String? selectedAudioId;
  @override
  String? selectedSubtitleId;

  void _tracksChanged() {
    emit();
    if (!_tracksReady || _disposed || player.state.completed) return;
    _tracksDirty = true;
    unawaited(
      _refreshTracks().catchError((Object _) {
        if (!_disposed) {
          log?.add(LogArea.player, '轨道信息更新失败，保留已有轨道', level: LogLevel.warning);
        }
      }),
    );
  }

  Future<void> _refreshTracks() async {
    if (_tracksBusy || _disposed || player.state.completed) return;
    final native = player.platform;
    if (native is! NativePlayer) return;
    _tracksBusy = true;
    try {
      do {
        _tracksDirty = false;
        final count =
            int.tryParse(await native.getProperty('track-list/count')) ?? 0;
        if (count < 0 || count > 512) throw const AppFailure('轨道数量超出上限');
        final metadata =
            <String, ({int? pid, int? ffIndex, bool forced, bool external})>{};
        Future<String?> optional(String key) async {
          try {
            return await native.getProperty(key);
          } catch (_) {
            return null;
          }
        }

        Future<void> sampleTrack(int i) async {
          if (_disposed) return;
          final prefix = 'track-list/$i/';
          final type = await native.getProperty('${prefix}type');
          if (type != 'sub' && type != 'audio') return;
          final values = await Future.wait([
            native.getProperty('${prefix}id'),
            optional('${prefix}src-id'),
            optional('${prefix}ff-index'),
            optional('${prefix}forced'),
            optional('${prefix}external'),
          ]);
          if (_disposed) return;
          metadata['$type:${values[0]}'] = (
            pid: int.tryParse(values[1] ?? ''),
            ffIndex: int.tryParse(values[2] ?? ''),
            forced: values[3] == 'yes',
            external: values[4] == 'yes',
          );
        }

        // Only existing in-memory MPV properties. Bound outstanding replies;
        // no media request, decoder change or playback guard is added/removed.
        for (var first = 0; first < count; first += 4) {
          await Future.wait([
            for (var i = first; i < count && i < first + 4; i++) sampleTrack(i),
          ]);
          if (_disposed) return;
        }
        if (_disposed) return;
        _trackMetadata
          ..clear()
          ..addAll(metadata);
        selectedAudioId = await native.getProperty('aid');
        final sid = await native.getProperty('sid');
        selectedSubtitleId =
            _externalIds.entries
                .where((e) => e.value == sid)
                .map((e) => e.key)
                .firstOrNull ??
            sid;
      } while (_tracksDirty && !_disposed);
      emit();
    } finally {
      _tracksBusy = false;
    }
  }

  TrackOption _trackOption(dynamic track, bool subtitles) {
    final String id = track.id;
    if (id == 'auto' || id == 'no') {
      return TrackOption(
        id,
        id == 'auto'
            ? (subtitles ? '自动 · 简体中文优先' : '自动 · 影片默认音轨')
            : (subtitles ? '关闭字幕' : '关闭音频'),
        track,
      );
    }
    final meta = _trackMetadata['${subtitles ? "sub" : "audio"}:$id'];
    final rawLanguage = (track.language as String?) ?? '';
    final external = meta?.external ?? false;
    final language = resolvedTrackLanguage(
      rawLanguage,
      meta?.pid,
      subtitles
          ? _disc?.selected?.subtitleLanguages
          : _disc?.selected?.audioLanguages,
      external: external,
    );
    final title = (track.title as String?) ?? '';
    final codec = (track.codec as String?) ?? '';
    final publicId =
        _externalIds.entries
            .where((e) => e.value == id)
            .map((e) => e.key)
            .firstOrNull ??
        id;
    return TrackOption(
      publicId,
      subtitles
          ? trackLabel(
              id: id,
              language: language,
              title: title,
              codec: codec,
              channels: subtitles ? null : track.channelscount as int?,
              external: external,
              isDefault: track.isDefault == true,
              forced: meta?.forced ?? false,
              subtitles: subtitles,
            )
          : compactAudioTrackLabel(
              language: language,
              title: title,
              codec: codec,
              channels: track.channelscount as int?,
              channelLayout: track.channels as String?,
            ),
      track,
      language: language,
      title: title,
      codec: codec,
      sourcePid: meta?.pid,
      ffIndex: _disc == null ? meta?.ffIndex : null,
      channels: subtitles ? null : track.channelscount as int?,
      external: external,
      forced: meta?.forced ?? false,
      isDefault: track.isDefault == true,
    );
  }

  PlaybackLatencyProbe? _latency;
  HttpPlaybackTrace Function(String)? _latencyHttp;

  void _beginLatency(String phase, Duration target) {
    final native = player.platform;
    if (_disposed || native is! NativePlayer || log?.enabled != true) return;
    final probe = _latency ??= PlaybackLatencyProbe(
      read: (key) =>
          native.getProperty(key).timeout(const Duration(milliseconds: 600)),
      write: (key, value) =>
          native.setProperty(key, value).timeout(const Duration(seconds: 2)),
      request: (level) => _nativeLogLevel(native, level),
      record: (fact) => log?.add(LogArea.player, fact),
    );
    final producer = _disc == null && !_opening && _openingLogs == null;
    final http = producer ? _latencyHttp?.call(phase) : null;
    probe.begin(
      phase: phase,
      target: target,
      producer: producer,
      http: http?.add,
      finishHttp: http?.finish,
    );
  }

  HttpPlaybackTrace? _trace;
  OpeningLogs? _openingLogs;
  DiscPacketTrace? _packetTrace;
  Timer? _packetTimer;
  String? _packetPreviousLevel;
  Future<void> _packetCleanup = Future.value();

  Future<void> _startPacketTrace(NativePlayer native) async {
    await _stopPacketTrace();
    if (_disposed || log?.enabled != true || _disc?.selected == null) return;
    try {
      _packetPreviousLevel = await native
          .getProperty('options/msg-level')
          .timeout(const Duration(milliseconds: 600));
      await native
          .setProperty('msg-level', 'all=warn,demux=trace,ffmpeg/video=trace')
          .timeout(const Duration(seconds: 2));
      if (_disposed) {
        await _stopPacketTrace();
        return;
      }
      _packetTrace = DiscPacketTrace();
      // Public API terminal-default honors the prefix whitelist even with
      // terminal output disabled. Global trace would trace HTTP/auth as well.
      if (_nativeLogLevel(native, 'terminal-default') < 0) {
        throw StateError('native log request failed');
      }
      _packetTimer = Timer(
        const Duration(seconds: 45),
        () => unawaited(_stopPacketTrace()),
      );
      log?.add(
        LogArea.player,
        '原盘数值诊断开始：最长 45 秒或 20000 条事件；'
        '只保留容器/时间线 PTS、DTS 与硬解入出队数值；每类首 4 条及末 12 条',
      );
    } catch (_) {
      await _stopPacketTrace();
      log?.add(LogArea.player, '原盘数值诊断未启用，播放继续沿用原配置', level: LogLevel.warning);
    }
  }

  Future<void> _stopPacketTrace() {
    _packetTimer?.cancel();
    _packetTimer = null;
    final trace = _packetTrace;
    final previous = _packetPreviousLevel;
    _packetTrace = null;
    _packetPreviousLevel = null;
    final native = player.platform;
    if (native is NativePlayer &&
        !native.disposed &&
        native.ctx.address != 0 &&
        (trace != null || previous != null)) {
      _nativeLogLevel(native, 'warn');
      _packetCleanup = _packetCleanup.then((_) async {
        if (previous == null || native.disposed) return;
        try {
          await native
              .setProperty('msg-level', previous)
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          log?.add(
            LogArea.player,
            '原生日志等级还原未确认，客户端已恢复警告级别',
            level: LogLevel.warning,
          );
        }
      });
    }
    for (final row in trace?.finish() ?? <String>[]) {
      log?.add(LogArea.player, row);
    }
    return _packetCleanup;
  }

  EmbyOriginTransport? _origin;
  DiscTransport? _disc;
  late final int _discCacheBytes;
  double _speed = 1;
  late final int _baseBufferBytes;
  @override
  double? get videoAspectRatio {
    if (_screenCanvas) {
      final aspect =
          _phoneFit?.adaptedAspect ??
          subtitlePictureAspect(player.state.videoParams);
      return aspect != null && aspect > 0 ? aspect : null;
    }
    final rect = video.rect.value;
    return rect != null && rect.width > 1 && rect.height > 1
        ? rect.width / rect.height
        : null;
  }

  late final _rates = PlaybackRateQueue(_applyRate);
  Timer? _discTimer;
  final _discClock = Stopwatch();
  final _bufferWatch = DiscBufferWatch();
  bool _healthBusy = false;
  @override
  int? discPlaylist;
  @override
  DiscKind? forcedDiscKind;
  @override
  List<DiscTitle> get discTitles => _disc?.titles ?? const [];
  @override
  int? get selectedDiscPlaylist => _disc?.selected?.playlist;
  @override
  String get discResourceType => switch (_disc?.kind) {
    DiscKind.iso => 'ISO',
    DiscKind.blurayFolder => 'BDMV',
    _ => '',
  };
  Future<void>? _nativeDiscRegistration;
  Future<void> _registerNativeDisc() async {
    final native = player.platform;
    if (native is! NativePlayer) throw const AppFailure('当前播放组件不支持原生原盘读取');
    final handle = await native.handle;
    if (DiscNativeApi().register(Pointer<Void>.fromAddress(handle)) < 0) {
      throw const AppFailure('原生原盘读取接口注册失败');
    }
  }

  Future<DiscTransport> _newDiscTransport(
    PlaybackRoute route,
    DiscKind kind, {
    String? address,
  }) async {
    if (_persistentCache == null) {
      await (_nativeDiscRegistration ??= _registerNativeDisc());
      return DiscWorkerTransport(
        route,
        kind: kind,
        address: address,
        log: log,
        onStage: _setStage,
        onFailure: _discFailed,
        cacheBytes: _discCacheBytes,
        directNative: true,
      );
    }
    return DiscTransport(
      route,
      kind: kind,
      address: address,
      backgroundOutput: true,
      log: log,
      onStage: _setStage,
      onFailure: _discFailed,
      cacheBytes: _discCacheBytes,
      persistentCache: _persistentCache,
      cacheScope: _cacheScope,
    );
  }

  bool _opening = false, _switching = false, _disposed = false;
  bool _initialDiscCushionUsed = false;
  int _playIntent = 0;
  int _nativeSeekSerial = 0, _nativeRestartSeekSerial = 0;
  int? _fastSeekNativeSerial;
  bool _audioRefreshBroken = false;
  int _audioChangeIntent = 0;
  Future<void> _audioChanges = Future.value();
  bool _discInterrupted = false;
  Completer<void>? _openFailure;
  String _stage = '正在打开媒体';
  int _loadSerial = 0;
  void _setStage(String value) {
    _stage = value;
    emit();
    log?.add(LogArea.player, value);
  }

  String _describe(Object error) {
    final localFailure = _origin?.localFailure;
    if (localFailure != null) return localFailure;
    final message = diagnostics.describe(error);
    final rejection = _origin?.rejection;
    final discError = _disc?.failure;
    return [
      message,
      ?_origin?.upstreamFailure,
      ?rejection,
      ?discError,
      ?_cachedTransport?.failure,
    ].join('\n');
  }

  String? _lastFailure;
  bool _readEofReported = false;
  void _discFailed(String message) {
    if (_disposed || _lastFailure != null) return;
    _discClockFault.clear();
    _discCacheRetention.cancel();
    _discInterrupted = true;
    _lastFailure = message;
    log?.add(LogArea.player, '原盘播放中断：$message', level: LogLevel.error);
    if (_opening) {
      if (_openFailure?.isCompleted == false) {
        _openFailure!.completeError(AppFailure(message));
      }
    } else if (!failures.isClosed) {
      failures.add(message);
    }
    _discTimer?.cancel();
    _decoderRecovery.cancel();
    final disc = _disc;
    if (disc != null) unawaited(disc.close());
  }

  Future<void> _recordDiagnosticContext(NativePlayer native) async {
    if (_contextBusy ||
        !_diagnosticBudget.allow(
          'context',
          _runtimeClock.elapsed,
          enabled: log?.enabled == true,
          playing: player.state.playing && !player.state.completed,
          interval: const Duration(seconds: 60),
        )) {
      return;
    }
    _contextBusy = true;
    final load = _loadSerial;
    bool active() =>
        !_disposed &&
        !_diagnosticBudget.stopped &&
        log?.enabled == true &&
        load == _loadSerial;
    try {
      final color = await colorDiagnostics(native.getProperty, active: active);
      if (!active()) return;
      if (color != null) log?.add(LogArea.player, color);
      try {
        final levels = await Device.levels().timeout(
          const Duration(milliseconds: 600),
        );
        if (active()) {
          log?.add(
            LogArea.player,
            '显示亮度核对：${Device.brightnessDescription(levels)}；HDR开关=$nativeHdr；实际HDR=${_hdr.established}；杜比映射=$_dolbyMapping',
          );
        }
      } catch (_) {
        /* Optional platform facts may be unavailable. */
      }
      if (!active()) return;
      try {
        final values = await Device.channel
            .invokeMapMethod<Object?, Object?>('resourceDiagnostics')
            .timeout(const Duration(milliseconds: 600));
        if (active() && values != null) {
          log?.add(LogArea.player, _resourceObservation.describe(values));
        }
      } catch (_) {
        if (active()) log?.add(LogArea.player, '进程资源快照=未提供；不能推定零占用或零耗电');
      }
    } finally {
      _contextBusy = false;
    }
  }

  @override
  void stopDiagnostics() {
    if (_diagnosticBudget.stopped) return;
    _diagnosticBudget.stop();
    _videoTimer?.cancel();
    _discTimer?.cancel();
    _packetTimer?.cancel();
    _rateProbe.cancel();
    _cancelBufferPhase();
    _latency?.finish('playback_exit');
    unawaited(_stopPacketTrace());
    unawaited(_openingLogs?.close());
    unawaited(log?.flush());
  }

  void _sampleDiscHealth() {
    if (_disposed ||
        _diagnosticBudget.stopped ||
        _opening ||
        _disc == null ||
        _lastFailure != null) {
      return;
    }
    final state = snapshot;
    if (_bufferWatch.sample(
      now: _discClock.elapsed,
      position: state.position,
      playing: state.playing,
      buffering: state.buffering,
      completed: state.completed,
    )) {
      _discFailed('原盘缓冲超过 60 秒，播放位置没有继续前进，请重试');
      return;
    }
    unawaited(_recordDiscHealth());
  }

  Future<void> _recordDiscHealth() async {
    if (_healthBusy ||
        !_diagnosticBudget.allow(
          'disc',
          _runtimeClock.elapsed,
          enabled: log?.enabled == true,
          playing: player.state.playing && !player.state.completed,
          abnormal: player.state.buffering,
        )) {
      return;
    }
    final native = player.platform;
    if (native is! NativePlayer) return;
    _healthBusy = true;
    try {
      await _disc?.refreshReadHealth();
      if (_disposed || _diagnosticBudget.stopped || _disc == null) return;
      final values = <String>[];
      for (final key in [
        'paused-for-cache',
        'demuxer-cache-duration',
        'cache-buffering-state',
        'cache-pause-wait',
        'demuxer-max-bytes',
        'decoder-frame-drop-count',
        'frame-drop-count',
      ]) {
        if (_disposed || _diagnosticBudget.stopped) return;
        try {
          final raw = await native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600));
          values.add(
            '$key=${num.tryParse(raw) != null || const {"yes", "no"}.contains(raw) ? raw : "未提供"}',
          );
        } catch (_) {
          values.add('$key=未提供');
        }
      }
      if (_disposed || _diagnosticBudget.stopped || _disc == null) return;
      final state = snapshot;
      log?.add(
        LogArea.player,
        '原盘运行：倍速=$_speed；位置=${state.position.inMilliseconds} ms；'
        '请求播放=${state.playing}；缓冲=${state.buffering}；${values.join("；")}；${_disc!.readHealth}',
      );
    } finally {
      _healthBusy = false;
    }
  }

  final subscriptions = <StreamSubscription>[];
  void emit() {
    if (!_disposed && !_opening && !_runtimeRepairBusy) {
      final accepted = _runtimePosition.accept(
        player.state.position,
        duration: player.state.duration,
      );
      if (!accepted && _runtimePosition.rejected && !_positionRejected) {
        if (_packetTrace != null) {
          _packetTimer?.cancel();
          _packetTimer = Timer(
            const Duration(seconds: 2),
            () => unawaited(_stopPacketTrace()),
          );
        }
        log?.add(
          LogArea.player,
          '播放时钟异常：原始=${player.state.position.inMilliseconds} ms；'
          '最后有效=${_runtimePosition.value.inMilliseconds} ms；等待音画状态核对',
          level: LogLevel.warning,
        );
      }
      _positionRejected = _runtimePosition.rejected;
      if (!_runtimePosition.settling) _seekSince = null;
    }
    if (!updates.isClosed) updates.add(snapshot);
  }

  @override
  Stream<PlaybackSnapshot> get changes => updates.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot(
    position: player.state.position,
    duration: player.state.duration,
    playing: player.state.playing,
    buffering: player.state.buffering,
    completed: player.state.completed,
    openingStage: _stage,
  );
  @override
  List<TrackOption> get audioTracks =>
      player.state.tracks.audio.map((t) => _trackOption(t, false)).toList();
  @override
  List<TrackOption> get subtitleTracks =>
      player.state.tracks.subtitle.map((t) => _trackOption(t, true)).toList();
  @override
  Widget view(BoxFit fit) => screenSubtitledVideo(
    picture: _hdr.view(
      Video(
        controller: video,
        controls: NoVideoControls,
        fit: _screenCanvas ? BoxFit.contain : fit,
        wakelock: false,
        subtitleViewConfiguration: const SubtitleViewConfiguration(
          visible: false,
        ),
      ),
      fit,
      subtitles: const SizedBox.shrink(),
    ),
    controller: video,
    configuration: _subtitleViewConfiguration,
    pictureAspect: videoAspectRatio,
    belowPicture: _subtitleAutomatic && !_subtitleDiscEmbedded,
    fill: _pictureFill,
    onDefaultPosition: _rememberSubtitleDefault,
  );

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

  // Read only this player's in-memory output. A valid texture or VO frame is
  // diagnostic evidence, not proof that the user saw a non-black image.
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

  Future<void> _repairHardwareFallback(
    NativePlayer native,
    HardwareRepairAction action,
  ) async {
    if (_disposed ||
        _opening ||
        _runtimeRepairBusy ||
        _hardwareRepairQueued ||
        _lastFailure != null) {
      return;
    }
    _hardwareRepairQueued = true;
    final generation = _hardwareFallback.generation;
    bool active() =>
        !_disposed &&
        !_opening &&
        !_discInterrupted &&
        _lastFailure == null &&
        generation == _hardwareFallback.generation;
    try {
      await _rates.run(() async {
        if (!active()) return;
        final target = _runtimePosition.value;
        _runtimeRepairBusy = true;
        ++_runtimeEpoch;
        _runtimeWatch.seek();
        _discClockFault.begin(
          load: _loadSerial,
          epoch: _runtimeEpoch,
          intent: _seekIntent,
        );
        _observation.invalidate();
        _runtimePosition.beginSeek(target);
        _seekSince = _runtimeClock.elapsed;
        log?.add(
          LogArea.player,
          '${action == HardwareRepairAction.retryHardware ? "运行中硬解失败：仅尝试一次原硬解重建" : "硬解重建后仍为软解：清理缺失参考帧"}；'
          '保留=${target.inMilliseconds} ms；倍速=$_speed；'
          '当前媒体内从关键帧恢复，不重新解析播放入口',
          level: LogLevel.warning,
        );
        try {
          await _beginFastBuffer('解码恢复');
          if (!active()) return;
          _cachedTransport?.seek();
          _disc?.resetReadAhead();
          // Reuse the existing bounded native restart/frame verifier. A
          // successful property write alone is not successful video recovery.
          _decoderRecovery.codecFailed('运行中硬件解码失败，等待解码重建');
          _armBufferPhase();
          await repairHardwareFallback(
            action: action,
            hardware: _hardwareFallback.hardware!,
            position: target,
            active: active,
            write: native.setProperty,
            seek: player.seek,
          );
        } catch (_) {
          if (active()) {
            _failPlayback('解码失败后的重建未完成，已保留观看位置，请重试');
          }
        } finally {
          _runtimeRepairBusy = false;
          if (!_disposed) emit();
        }
      });
    } finally {
      _hardwareRepairQueued = false;
    }
  }

  Future<void> _prepareOpeningSubtitles(
    NativePlayer native,
    String address,
    Duration start,
    bool Function() active,
  ) async {
    final choose = _openingSubtitleChoice;
    if (choose == null || address.isEmpty || !active()) return;
    Future<String> read(String key) =>
        native.getProperty(key, waitForInitialization: false);
    Future<void> write(String key, String value) =>
        native.setProperty(key, value, waitForInitialization: false);
    final before = <String, String>{};
    try {
      if (await read('path') != address || !active()) return;
      final parsed = await readOpeningSubtitles(
        read,
        active,
        discLanguages: _disc?.selected?.subtitleLanguages,
      );
      if (!active() || parsed.length <= 2 || await read('path') != address) {
        return;
      }
      final target = choose(parsed);
      final secondary = openingSecondaryChoice?.call(parsed);
      final secondaryId =
          secondary != null &&
              !secondary.control &&
              !secondary.external &&
              !secondary.bitmap &&
              target?.bitmap != true &&
              secondary.id != target?.id
          ? secondary.id
          : 'no';
      if (secondaryId != 'no' ||
          (int.tryParse(await read('secondary-sid')) ?? 0) > 0) {
        before['secondary-sid'] = await read('secondary-sid');
        await write('secondary-sid', secondaryId);
        if (!active()) return;
        if (await read('secondary-sid') != secondaryId) {
          throw StateError('Secondary subtitle not selected');
        }
        secondarySubtitleId = secondaryId;
      }
      if (target == null ||
          target.external ||
          target.id == 'auto' ||
          !parsed.any((t) => t.id == target.id)) {
        return;
      }
      before['sid'] = await read('options/sid');
      before['sub-visibility'] = await read('sub-visibility');
      if (!active() ||
          !(before['sid'] == 'auto' ||
              before['sid'] == 'no' ||
              int.tryParse(before['sid']!) != null) ||
          !const {'yes', 'no'}.contains(before['sub-visibility'])) {
        return;
      }
      await write('sid', target.id);
      if (!active()) return;
      if (await read('options/sid') != target.id) {
        throw StateError('Initial subtitle not selected');
      }
      final visible = target.id != 'no' && target.bitmap ? 'yes' : 'no';
      await write('sub-visibility', visible);
      if (!active()) return;
      if (await read('sub-visibility') != visible) {
        throw StateError('Initial subtitle visibility not applied');
      }
      var preroll = false;
      if ((target.id != 'no' || secondaryId != 'no') && start > Duration.zero) {
        preroll = await _openingSubtitleRead.prepare(
          container: await read('file-format'),
          read: read,
          write: write,
          active: active,
        );
      }
      if (!active()) return;
      log?.add(
        LogArea.player,
        '续播字幕准备：定位前已选轨道=${target.id}；类型=${target.bitmap ? "图像" : "文字"}；预滚已确认=$preroll；最多提前读取10秒媒体数据；精确目标保持；未代替实际字幕显示核对',
      );
    } catch (_) {
      if (!active()) return;
      for (final key in before.keys.toList().reversed) {
        if (!active()) return;
        await write(key, before[key]!);
        final property = key == 'sid' ? 'options/sid' : key;
        if (await read(property) != before[key]) {
          _failPlayback('续播字幕准备失败，原字幕状态未能恢复');
          return;
        }
      }
      log?.add(
        LogArea.player,
        '定位前字幕准备暂不可用，沿用原轨道选择与真实错误核对',
        level: LogLevel.warning,
      );
    }
  }

  @override
  Future<void> open(PlaybackRoute route, Duration start) async {
    if (_hdr.autoDolby) {
      if (_hdr.established || _hdr.autoArmed) await player.stop();
      await _hdr.resetAuto();
    } else {
      await _hdr.resetAuto();
    }
    unawaited(_hdr.start());
    if (nativeHdr && requestsDolbyMapping(route.streams)) {
      unawaited(_hdr.warmDolby(deferHlg: true));
    }
    ++_playIntent;
    ++_seekIntent;
    ++_audioChangeIntent;
    await _latency?.stop('load_changed');
    _latencyHttp = null;
    // Finish restoring a cancelled audio refresh before configuring a new load.
    await _rates.run(() async {});
    if (_audioRefreshBroken) {
      throw const AppFailure('音轨刷新参数恢复失败，请退出播放器后重试');
    }
    _initialDiscCushionUsed = false;
    await _stopPacketTrace();
    _networkFile = const {
      'http',
      'https',
    }.contains(Uri.tryParse(route.url)?.scheme);
    _cancelBufferPhase();
    _bufferPhase.begin();
    _streamBuffer.beginFast();
    ++_runtimeEpoch;
    _runtimeWatch.reset();
    _videoLoss.reset();
    _discClockFault.clear();
    _discPtsLoad = null;
    _discMissingVideoPts = false;
    _audioDecode.cancel();
    _hardwareFallback.reset();
    _dolbyRecovery.reset();
    _observation.invalidate();
    _runtimePosition.reset(start);
    _diagnosticBudget.reset();
    _resourceObservation.reset();
    _positionRejected = false;
    _seekSince = null;
    _fastSeekIntent = null;
    _fastSeekNativeSerial = null;
    diagnostics.clear();
    _videoDiagnostics.clear();
    _openingVideoTrace.clear();
    _videoTimer?.cancel();
    _lastFailure = null;
    _autoHdrRecovery.reset();
    _readEofReported = false;
    _decoderOpeningError = null;
    _noticeReady = false;
    _noticeDecoded = const {};
    _discInterrupted = false;
    _opening = true;
    _openFailure = Completer<void>();
    unawaited(_openFailure!.future.catchError((Object _) {}));
    final detected = Completer<({DiscKind kind, String address})>();
    var opened = false;
    try {
      var mediaAddress = route.url;
      final discKind = forcedDiscKind ?? route.discKind;
      if (discKind != DiscKind.none) {
        final disc = await _newDiscTransport(route, discKind);
        if (_disposed) {
          await disc.close();
          throw const AppFailure('播放已退出');
        }
        _disc = disc;
        mediaAddress = await disc.start(playlist: discPlaylist);
      } else if (route.sameOriginHeaders.isNotEmpty) {
        final origin = EmbyOriginTransport(
          route,
          log: log,
          onDisc: (kind, address) {
            if (!detected.isCompleted) {
              detected.complete((kind: kind, address: address));
            }
          },
        );
        _origin = origin;
        mediaAddress = await origin.start();
      }
      if (_disposed) throw const AppFailure('播放已退出');
      if (_disc == null && _persistentCache != null && _networkFile) {
        final cached = CachedPlaybackTransport(
          address: mediaAddress,
          headers: route.headers,
          cache: _persistentCache!,
          scope: _cacheScope,
        );
        _cachedTransport = cached;
        mediaAddress = await cached.start();
      }
      Future<void> loadVideo(String address) async {
        final serial = ++_loadSerial;
        _beginDiscTimestampScope(serial);
        final loadClock = Stopwatch()..start();
        final native = player.platform;
        if (native is! NativePlayer) throw const AppFailure('MPV 原生后端未就绪');
        await _openingSubtitleRead.restore(
          read: native.getProperty,
          write: native.setProperty,
        );
        await _shadow.set(
          0,
          pictureBrightness: 0,
          read: native.getProperty,
          write: native.setProperty,
          active: () => !_disposed && serial == _loadSerial,
        );
        final shaderCache = await prepareShaderCache(
          read: (key) => native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600)),
          write: (key, value) => native
              .setProperty(key, value)
              .timeout(const Duration(seconds: 2)),
          active: () => !_disposed && serial == _loadSerial,
        );
        if (shaderCache == ShaderCacheSetupResult.ready) {
          log?.add(LogArea.player, '已配置本应用图形着色器缓存；可用时复用编译结果，原画与色彩设置保持');
        }
        final dolby = requestsDolbyMapping(route.streams);
        {
          if (dolby != _dolbyMapping) await player.stop();
          final changed = await video.setDolbyMapping(dolby);
          _dolbyMapping = dolby;
          if (changed) {
            log?.add(
              LogArea.player,
              dolby
                  ? '杜比片源启用逐帧色彩映射；硬解须支持原始 YUV 交接，否则使用内核后备解码；不转码'
                  : '已恢复普通媒体的原视频输出与解码设置',
            );
          }
        }
        final oldHook = _dolbyPreloadedHook;
        if (oldHook != null) native.onPreloadedHooks.remove(oldHook);
        _dolbyPreloadedHook = () async {
          bool active() =>
              !_disposed && serial == _loadSerial && _lastFailure == null;
          if (!active()) return;
          await _prepareOpeningSubtitles(native, address, start, active);
          if (!active()) return;
          log?.add(
            LogArea.player,
            '内核开播分段：本次媒体解析完成=${loadClock.elapsedMilliseconds} ms；尚未确认出画',
          );
          try {
            final profile = await prepareOpenedDolby(
              address: address,
              read: (key) =>
                  native.getProperty(key, waitForInitialization: false),
              enable: () async {
                await video.setDolbyMapping(true);
                _dolbyMapping = true;
              },
              active: active,
            );
            if (!active()) return;
            if (nativeHdr && profile != null) {
              unawaited(_hdr.warmDolby(deferHlg: true));
            } else {
              _hdr.cancelWarm();
            }
            {
              final surfaceClock = Stopwatch()..start();
              final prepared = await prepareOpenedVideoSurface(
                address: address,
                read: (key) =>
                    native.getProperty(key, waitForInitialization: false),
                prepare: (w, h) => video.prepareVideoSurface(w, h, active),
                active: active,
              );
              if (!active()) return;
              var hardwarePolicy = '未提供';
              try {
                final value = await native.getProperty(
                  'options/hwdec',
                  waitForInitialization: false,
                );
                if (const {
                  'auto',
                  'auto-safe',
                  'mediacodec',
                  'mediacodec-copy',
                  'no',
                }.contains(value)) {
                  hardwarePolicy = value;
                }
              } catch (_) {
                /* Optional startup diagnostic. */
              }
              if (!active()) return;
              log?.add(
                LogArea.player,
                '解码前画面表面准备：已确认=$prepared；耗时=${surfaceClock.elapsedMilliseconds} ms；硬解策略=$hardwarePolicy；未代替实际出画核对',
              );
            }
            if (!active()) {
              _hdr.cancelWarm();
              return;
            }
            if (nativeHdr && profile != null && _disc == null) {
              final selected = await _hdr.claimWarm();
              log?.add(
                LogArea.player,
                selected
                    ? '[HDR180] 解码前已选择就绪的杜比HDR窗口；不重开媒体或定位'
                    : '[HDR180] HDR候选未通过准入，沿用当前SDR；原因=${_hdr.status}',
              );
              if (!selected) await _hdr.resetAuto();
            } else {
              _hdr.cancelWarm();
            }
            log?.add(
              LogArea.player,
              profile == null
                  ? '实际媒体已解析：容器未提供可用杜比 Profile；保留已有片源设置，不能据此排除杜比'
                  : '实际媒体识别：杜比视界 Profile $profile；已在解码前启用逐帧映射；复用本次取流',
            );
          } catch (_) {
            if (!active()) return;
            await native.setProperty(
              'pause',
              'yes',
              waitForInitialization: false,
            );
            _failPlayback('已识别杜比资源，但杜比输出初始化失败，已保留观看进度');
          }
        };
        native.onPreloadedHooks.add(_dolbyPreloadedHook!);
        await native.setProperty('network-timeout', '30');
        if (Platform.isAndroid) {
          await native.setProperty(
            'yingyu-copy-queue',
            '${playbackCopyQueueBytes(_baseBufferBytes)}',
          );
        }
        _selectSubtitlePlacement(_disc?.selected != null);
        if (_screenCanvas) {
          if (_subtitleDiscEmbedded && _subtitleAutomatic) {
            await writeMpvSubtitleLayout(
              scope: SubtitlePositionScope.discEmbedded,
              read: native.getProperty,
              write: native.setProperty,
              active: () => !_disposed && serial == _loadSerial,
            );
          } else {
            await native.setProperty('yingyu-subtitle-screen-position', 'yes');
            if (await native.getProperty('yingyu-subtitle-screen-position') !=
                'yes') {
              throw const AppFailure('字幕屏幕位置初始化失败');
            }
            final placement = _subtitleAutomatic ? 'yes' : 'no';
            await native.setProperty(
              'yingyu-subtitle-below-picture',
              placement,
            );
            if (await native.getProperty('yingyu-subtitle-below-picture') !=
                placement) {
              throw const AppFailure('字幕默认位置初始化失败');
            }
          }
          final remembered = _initialSubtitlePosition;
          if (remembered != null) {
            try {
              await writeMpvSubtitlePosition(
                value: remembered,
                read: native.getProperty,
                write: native.setProperty,
                active: () => !_disposed && serial == _loadSerial,
              );
            } catch (_) {
              // A stale/unsupported preference must not prevent media opening.
              if (_disposed || serial != _loadSerial) rethrow;
              try {
                final defaults = _subtitleDiscEmbedded
                    ? const {
                        'stretch-image-subs-to-screen': 'no',
                        'sub-pos': '100',
                        'yingyu-subtitle-below-picture': 'no',
                        'yingyu-subtitle-screen-position': 'no',
                      }
                    : const {'yingyu-subtitle-below-picture': 'yes'};
                for (final entry in defaults.entries) {
                  if (_disposed || serial != _loadSerial) {
                    throw const AppFailure('播放会话已改变');
                  }
                  await native.setProperty(entry.key, entry.value);
                }
              } catch (_) {
                // Position is optional; a failed preference must not turn an
                // otherwise healthy movie into a playback error.
              }
              _subtitleAutomatic = true;
              _initialSubtitlePosition = null;
              _subtitleViewConfiguration = const SubtitleViewConfiguration();
              log?.add(
                LogArea.player,
                '字幕位置记忆未确认，已尝试恢复默认；可在字幕位置中重新调整',
                level: LogLevel.warning,
              );
            }
          }
        }
        final indexed = await _discSeekIndex.prepare(
          index: _disc?.seekIndex ?? '',
          read: native.getProperty,
          write: native.setProperty,
        );
        if (indexed) {
          log?.add(LogArea.player, '原盘已启用 CLPI 访问点定位；目标位置、轨道探测与原画保持');
        }
        final fastResume = await _startupSeek.prepare(
          read: (key) => native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600)),
          write: (key, value) => native
              .setProperty(key, value)
              .timeout(const Duration(seconds: 2)),
        );
        if (fastResume) {
          log?.add(LogArea.player, '首次精确定位：允许解码器跳过目标前的帧；目标位置与原画输出保持');
        }
        // Persistent raw ranges replace the unbounded temporary packet dump.
        // The existing device-based packet RAM limit remains in force.
        if (_persistentCache != null) {
          await native.setProperty('cache-on-disk', 'no');
        }
        final audioSetup = await _rateAudio.prepare(
          read: (key) => native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600)),
          write: native.setProperty,
        );
        log?.add(LogArea.player, '切速音频准备：${audioSetup.join('；')}');
        final probe = await _discProbe.prepare(
          disc: _disc?.selected != null,
          read: (key) => native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600)),
          write: native.setProperty,
        );
        if (probe != null) log?.add(LogArea.player, probe);
        if (_disc != null) {
          final startup = await _discStartup.prepare(
            hasPlaylistTimeline: _disc!.selected != null,
            read: (key) => native
                .getProperty(key)
                .timeout(const Duration(milliseconds: 600)),
            command: native.command,
          );
          log?.add(LogArea.player, startup);
        }
        await _rates.run(() => _beginFastBuffer('开播'));
        await _rates.run(() async {
          await _initialStreamBuffer.prepare(
            enabled: false,
            read: native.getProperty,
            write: native.setProperty,
          );
        });
        final cacheSetup = await _discCache.prepare(
          disc: _disc?.selected != null,
          read: (key) => native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600)),
          write: (key, value) => native
              .setProperty(key, value)
              .timeout(const Duration(seconds: 2)),
        );
        if (cacheSetup) {
          log?.add(LogArea.player, '原盘缓存按实际已选音视频中的较短可读时长计算；倍速门槛和预读预算保持');
        }
        await _rates.run(() async {
          if (_disposed || serial != _loadSerial) return;
          final initial = await _initialStreamBuffer.prepare(
            enabled: _networkFile && _disc == null,
            read: native.getProperty,
            write: native.setProperty,
          );
          if (initial) {
            log?.add(LogArea.player, '普通网络影片已启用原有起播缓存条件；无固定等待或额外请求');
          }
        });
        final timestampSetup = await _discTimestamps.prepare(
          disc: _disc?.selected != null,
          read: (key) => native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600)),
          command: (args) =>
              native.command(args).timeout(const Duration(seconds: 2)),
        );
        if (timestampSetup != null) log?.add(LogArea.player, timestampSetup);
        await _startPacketTrace(native);
        final agent =
            route.headers.entries
                .where((e) => e.key.toLowerCase() == 'user-agent')
                .map((e) => e.value)
                .firstOrNull ??
            playbackUserAgent;
        await native.setProperty('user-agent', agent);
        if (log?.enabled == true && _disc == null) {
          _latencyHttp = (phase) => HttpPlaybackTrace(
            log: log!,
            address: address,
            headers: route.headers,
            serverBase: route.serverBase,
            phase: phase,
          );
          _trace = HttpPlaybackTrace(
            log: log!,
            address: address,
            headers: route.headers,
            serverBase: route.serverBase,
          );
          // Limit at the native producer: parser limits alone still deliver
          // every packet/frame through the Dart event loop. Disc diagnostics
          // own a separate scope and never enter this ordinary-media branch.
          final openingLogs = OpeningLogs(
            read: (key) => native
                .getProperty(key)
                .timeout(const Duration(milliseconds: 600)),
            write: (key, value) => native
                .setProperty(key, value)
                .timeout(const Duration(seconds: 2)),
            request: (level) => _nativeLogLevel(native, level),
          );
          _openingLogs = openingLogs;
          await openingLogs.start();
          log?.add(
            LogArea.player,
            '开播诊断接收协议与固定解码候选原因，最长8秒；不订阅逐包、逐帧追踪，真实警告与错误保留',
          );
        }
        // An explicit empty map clears media-kit's same-URL header cache.
        final outputReady = _decoderRecovery.beginLoad();
        _armBufferPhase();
        log?.add(
          LogArea.player,
          '内核开播分段：加载前配置=${loadClock.elapsedMilliseconds} ms',
        );
        // MKV copies its demuxer options while opening, before on_preloaded.
        // Set the subtitle window before that snapshot; select the actual
        // subtitle in the hook. No subtitle packets are requested by this IO.
        if (start > Duration.zero && _openingSubtitleChoice != null) {
          await _openingSubtitleRead.prepare(
            container: 'mkv',
            read: (key) =>
                native.getProperty(key, waitForInitialization: false),
            write: (key, value) =>
                native.setProperty(key, value, waitForInitialization: false),
            active: () => !_disposed && serial == _loadSerial,
          );
        }
        await player.open(
          Media(
            address,
            httpHeaders: _disc == null ? route.headers : const {},
            start: start,
            extras: _disc != null && _disc!.base == 'yingyu-disc://${_disc!.id}'
                ? {'yingyuNativeDiscSession': _disc!.id}
                : const {},
          ),
          play: false,
        );
        // In the fixed Android plugin this future also completes on surface
        // dimensions. Require MPV restart and a frame in the real VO separately.
        await video.waitUntilFirstFrameRendered;
        if (!_disposed && serial == _loadSerial) {
          log?.add(
            LogArea.player,
            '内核开播分段：首帧画布通知=${loadClock.elapsedMilliseconds} ms；继续核对实际输出',
          );
        }
        await outputReady;
        log?.add(
          LogArea.player,
          '内核开播分段：输出帧就绪=${loadClock.elapsedMilliseconds} ms',
        );
        if (_disposed || serial != _loadSerial) {
          throw const AppFailure('播放打开已取消');
        }
        if (player.state.width == null || player.state.width! <= 0) {
          throw const AppFailure('MPV 未就绪');
        }
        log?.add(
          LogArea.player,
          'MPV 视频输出已就绪，输出持有帧；${player.state.width} × ${player.state.height}',
        );
        _videoLoss.reset(expectedVideo: true);
      }

      _setStage(_disc == null ? '正在连接媒体并等待首帧' : '原盘已解析，正在等待视频首帧');
      final switched =
          await Future.any<Object?>([
            loadVideo(mediaAddress).then((_) => null),
            _openFailure!.future.then((_) => null),
            detected.future,
          ]).timeout(
            Duration(seconds: _disc == null ? 40 : 90),
            onTimeout: () => throw AppFailure(
              _describe(
                '$_stage 超时；${_disc == null ? 40 : 90} 秒内未收到首帧${_decoderOpeningError == null ? "" : "；$_decoderOpeningError"}',
              ),
            ),
          );
      if (switched is ({DiscKind kind, String address})) {
        _switching = true;
        ++_loadSerial;
        await player.stop();
        await _cachedTransport?.close();
        _cachedTransport = null;
        await _origin?.close();
        _origin = null;
        _trace?.finish();
        _trace = null;
        await _openingLogs?.close();
        _openingLogs = null;
        diagnostics.clear();
        final disc = await _newDiscTransport(
          route,
          switched.kind,
          address: switched.address,
        );
        if (_disposed) {
          await disc.close();
          throw const AppFailure('播放已退出');
        }
        _disc = disc;
        final discAddress = await disc.start(playlist: discPlaylist);
        if (_disposed) throw const AppFailure('播放已退出');
        _switching = false;
        _openFailure = Completer<void>();
        unawaited(_openFailure!.future.catchError((Object _) {}));
        await Future.any([
          loadVideo(discAddress),
          _openFailure!.future,
        ]).timeout(
          const Duration(seconds: 90),
          onTimeout: () => throw AppFailure(
            _describe(
              '原盘已解析，但 MPV 90 秒内未收到首帧${_decoderOpeningError == null ? "" : "；$_decoderOpeningError"}',
            ),
          ),
        );
      }
      final finishing = Stopwatch()..start();
      await _recordOutput(route);
      log?.add(
        LogArea.player,
        '开播收尾：显示信息与色彩设置=${finishing.elapsedMilliseconds} ms',
      );
      finishing.reset();
      // Metadata uses MPV's in-memory track properties and the title information
      // already parsed by VideoLAN. No additional media probe is performed.
      try {
        await _refreshTracks();
      } catch (_) {
        log?.add(LogArea.player, '轨道元数据暂不可用，可手动选择', level: LogLevel.warning);
      }
      _tracksReady = true;
      log?.add(LogArea.player, '开播收尾：轨道资料=${finishing.elapsedMilliseconds} ms');
      if (_openFailure?.isCompleted == true) await _openFailure!.future;
      if (_disposed) throw const AppFailure('播放已退出');
      opened = true;
      {
        unawaited(_recordVideoHealth());
        _videoTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
          if (_disposed || _diagnosticBudget.stopped || _lastFailure != null) {
            timer.cancel();
          } else {
            unawaited(_recordVideoHealth());
          }
        });
      }
      if (_disc != null) {
        _bufferWatch.reset();
        _discClock.start();
        _discTimer?.cancel();
        _discTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _sampleDiscHealth(),
        );
      }
    } finally {
      if (!opened) {
        await _stopPacketTrace();
        _cancelBufferPhase();
        _decoderRecovery.cancel();
        ++_loadSerial;
        await _origin?.close();
        await _disc?.close();
        await _cachedTransport?.close();
        if (!_disposed) {
          try {
            await player.stop().timeout(const Duration(seconds: 5));
          } catch (_) {}
        }
      }
      _opening = false;
      _switching = false;
      _trace?.finish();
      _trace = null;
      await _openingLogs?.close();
      _openingLogs = null;
      final native = player.platform;
      if (native is NativePlayer &&
          !native.disposed &&
          native.ctx.address != 0) {
        if (!opened) {
          await _openingSubtitleRead.restore(
            read: native.getProperty,
            write: native.setProperty,
          );
        }
        if (_packetTrace == null) _nativeLogLevel(native, 'warn');
        await _startupSeek.restore(
          read: (key) => native
              .getProperty(key)
              .timeout(const Duration(milliseconds: 600)),
          write: (key, value) => native
              .setProperty(key, value)
              .timeout(const Duration(seconds: 2)),
        );
      }
      if (opened) {
        // Persistence owns its serialized write queue and reports failures.
        // A ready picture must not wait for up to 5000 log records on disk.
        unawaited(log?.flush());
      } else {
        await log?.flush();
      }
    }
  }

  int _nativeLogLevel(NativePlayer native, String level) {
    final value = level.toNativeUtf8();
    try {
      return native.mpv.mpv_request_log_messages(native.ctx, value.cast());
    } finally {
      calloc.free(value);
    }
  }

  @override
  PlaybackMediaFacts get mediaFacts {
    final native = player.platform;
    final epoch = _runtimeEpoch;
    if (native is! NativePlayer ||
        _disposed ||
        _opening ||
        native.disposed ||
        native.ctx.address == 0) {
      return const PlaybackMediaFacts();
    }
    // These are the same in-memory properties used by NativePlayer.getProperty.
    // The decoder already populated them while producing the frame. Reading
    // them synchronously lets the panel paint immediately: no HTTP, probe,
    // separate information cache, background collector or polling timer.
    String read(String key) {
      final name = key.toNativeUtf8();
      try {
        final value = native.mpv.mpv_get_property_string(
          native.ctx,
          name.cast(),
        );
        if (value.address == 0) return '';
        try {
          return value.cast<Utf8>().toDartString();
        } finally {
          native.mpv.mpv_free(value.cast());
        }
      } finally {
        calloc.free(name);
      }
    }

    return readPlaybackMediaFacts(
      read: read,
      active: () => !_disposed && !_opening && epoch == _runtimeEpoch,
    );
  }

  Future<void> _recordOutput(PlaybackRoute route) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed) return;
    _pendingHdrTransfer = null;
    if (_hdr.autoArmed && !await _hdr.confirmWarm()) {
      // A rejected first frame restored SDR. Release the optional admission
      // owner so the decoded HDR10/HLG transaction can still be considered.
      await _hdr.resetAuto();
    }
    final serial = _loadSerial;
    final values = await openingOutputProperties(
      native.getProperty,
      active: () => !_disposed && serial == _loadSerial,
    );
    if (_disposed || serial != _loadSerial) return;
    var detectedRange = DetectedVideoRange.unknown;
    var detectedContainer = '';
    if (nativeHdr) {
      try {
        final profile = await native.getProperty(
          'yingyu-hdr-source-dv-profile',
        );
        detectedContainer = await native.getProperty('file-format');
        if (_disposed || serial != _loadSerial) return;
        detectedRange = detectVideoRange(values, profile);
        log?.add(
          LogArea.player,
          '实际片源动态范围检测：${detectedRange.name}；依据当前视频轨和已解码色彩，服务器标签仅作参考',
        );
      } catch (_) {
        detectedRange = DetectedVideoRange.unknown;
      }
      // Positive observations of an ordinary HDR frame can supersede an
      // inaccurate server label. Actual Dolby and unknown stay unchanged.
      if (_dolbyMapping &&
          _disc == null &&
          supportedHdrContainer(detectedContainer) &&
          const {
            DetectedVideoRange.hdr10,
            DetectedVideoRange.hlg,
          }.contains(detectedRange)) {
        try {
          await video.setDolbyMapping(false);
        } catch (_) {
          throw const AppFailure('实际片源输出设置恢复失败，已保留观看进度');
        }
        _dolbyMapping = false;
        log?.add(LogArea.player, '当前实际轨为普通 HDR；已撤销服务器杜比标签触发的预设，按实际片源协商显示');
      }
    }
    _hardwareFallback.observeHardware(values['hwdec-current'] ?? '');
    log?.add(
      LogArea.player,
      '实际解码信息：${values.entries.map((e) => '${e.key}=${e.value}').join('；')}',
    );
    _noticeBluray = _disc?.selected != null;
    _noticeStreams = route.streams;
    _noticeDecoded = {
      ...values,
      'dolby-vision-profile':
          values['current-tracks/video/dolby-vision-profile'] ?? '',
    };
    _noticeReady = true;
    if (values['video-params/colormatrix'] == 'dolbyvision') {
      log?.add(
        LogArea.player,
        '检测到杜比视界色彩标记；逐帧映射=${_dolbyMapping ? '已启用' : '未启用'}；不代表设备原生杜比显示或完整 FEL 增强层处理',
        level: LogLevel.warning,
      );
    }
    if (!_hdr.dolbyEstablished &&
        const {'pq', 'hlg'}.contains(values['video-params/gamma'])) {
      // The existing Flutter texture pipeline has no verified Android HDR
      // surface contract. Use MPV's documented SDR tone mapping explicitly.
      for (final entry in const {
        'target-prim': 'bt.709',
        'target-trc': 'bt.1886',
        'tone-mapping': 'bt.2390',
        'dither': 'fruit',
        'dither-depth': '8',
      }.entries) {
        try {
          await native.setProperty(entry.key, entry.value);
          final actual = await native.getProperty('options/${entry.key}');
          log?.add(
            LogArea.player,
            'HDR 显示参数：${entry.key}=$actual（目标为 SDR 兼容显示）',
          );
        } catch (_) {
          log?.add(
            LogArea.player,
            'HDR 显示参数未能设置：${entry.key}',
            level: LogLevel.warning,
          );
        }
      }
    }
    log?.add(LogArea.player, '音频采用解码输出；TrueHD／E-AC-3 不等同于 Atmos 对象输出，未启用直通');
    if (nativeHdr && _disc == null && !_hdr.autoDolby) {
      await _hdr.start();
      try {
        final transfer =
            detectedRange == DetectedVideoRange.dolby && _dolbyMapping
            ? (_hdr.capabilities.hdr.contains(2)
                  ? 'pq'
                  : _hdr.capabilities.hdr.contains(3)
                  ? 'hlg'
                  : null)
            : nativeHdrTransfer(
                requested: nativeHdr,
                disc: _disc != null,
                source: detectedRange,
                container: detectedContainer,
                capabilities: _hdr.capabilities,
              );
        final paused = transfer == null
            ? ''
            : await native.getProperty('pause');
        log?.add(
          LogArea.player,
          'HDR 输出准入：动态范围=${detectedRange.name}；容器=${supportedHdrContainer(detectedContainer) ? detectedContainer : '其他或未知'}；'
          'SDK=${_hdr.capabilities.sdk}；屏幕HDR=${_hdr.capabilities.hdr.toList()..sort()}；'
          '候选=${transfer ?? '无'}；已暂停=$paused',
        );
        if (!_disposed &&
            serial == _loadSerial &&
            transfer != null &&
            paused == 'yes') {
          // Selecting a newly enabled subtitle may refresh the demuxer and
          // invalidate its queues. Finish initial track selection first, then
          // let the existing HDR exact refill rebuild all selected streams.
          // There is still only one HDR attempt and one successful refill.
          _pendingHdrTransfer = transfer;
          log?.add(LogArea.player, 'HDR 输出等待初始轨道处理；保持暂停与加载遮罩');
        }
      } catch (_) {
        log?.add(
          LogArea.player,
          'HDR 输出事务失败：${_hdr.status}；${await video.nativeHdrStatus}',
          level: LogLevel.warning,
        );
        _failPlayback('HDR 输出参数恢复失败，已保留观看进度');
      }
    }
    log?.add(LogArea.player, '当前播放方式提示：$sourceNotice');
    if (log?.enabled == true && _pendingHdrTransfer == null) {
      unawaited(
        displayDiagnostics(
          native.getProperty,
          active: () =>
              !_disposed && !_diagnosticBudget.stopped && serial == _loadSerial,
        ).then((values) {
          if (values.isNotEmpty) {
            log?.add(
              LogArea.player,
              '显示与缓存参数核对：${values.entries.map((e) => '${e.key}=${e.value}').join('；')}；磁盘缓存启用时字节上限仅约束包元数据',
            );
          }
        }),
      );
    }
  }

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

  @override
  Future<void> rate(double value) {
    // Invalidate a cache expiry before it can wait behind this new intent.
    _discCacheRetention.cancel();
    return _rates.set(value);
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

  void _retainDiscCache() {
    if (_disposed || _lastFailure != null || _discInterrupted) return;
    // The user explicitly retains the highest pre-read target after a hold.
    // Actual speed and its resume gate still return immediately.
    _discCacheRetention.cancel();
    final plan = _appliedDiscPlan;
    if (plan != null && !plan.fast && plan.tier > discBufferTier(_speed)) {
      log?.add(
        LogArea.player,
        '实际倍速=$_speed；预读缓存档=${plan.tier} 保持至本次视频关闭；'
        '恢复播放门槛=${plan.options["cache-pause-wait"]} 秒媒体时间',
      );
    }
  }

  Future<void> _releaseDiscCache(int generation, double tier) async {
    bool current() =>
        !_disposed &&
        _lastFailure == null &&
        !_discInterrupted &&
        _disc != null &&
        !_bufferPhase.fast &&
        _discCacheRetention.isCurrent(generation);
    try {
      if (!current()) return;
      // The optional device-memory query must not occupy the speed/seek queue.
      final plan = (await _discPlan(
        tier,
        fast: false,
      )).withPlaybackSpeed(_speed);
      if (!current()) return;
      await _rates.run(() async {
        if (!current()) return;
        await _setDiscPlan(plan);
        if (!current()) return;
        log?.add(LogArea.player, '预读缓存逐档回落；实际倍速=$_speed；$_discPlanDescription');
        _retainDiscCache();
      });
    } catch (_) {
      if (current()) {
        log?.add(
          LogArea.player,
          '预读缓存回落失败，保留已恢复的缓存参数；实际倍速没有延迟或改变',
          level: LogLevel.warning,
        );
      }
    }
  }

  String get _discPlanDescription {
    final plan = _appliedDiscPlan;
    if (plan == null) return '原盘缓存尚未配置';
    return '${plan.fast ? "快速出画面" : "持续预读"}；缓存档=${plan.tier}；'
        '前向包缓存上限=${plan.bytes ~/ 1048576} MiB；'
        '恢复播放目标=${plan.options["cache-pause-wait"]} 秒媒体时间';
  }

  Future<DiscBufferPlan> _discPlan(double speed, {required bool fast}) async {
    var memoryMiB = 32;
    if (_disc != null && !fast && speed > 1) {
      try {
        memoryMiB = await Device.memory().timeout(const Duration(seconds: 2));
      } catch (_) {
        // A failed optional query uses the conservative device tier.
      }
    }
    return DiscBufferPlan(
      speed: speed,
      fast: fast,
      baseBytes: _baseBufferBytes,
      memoryMiB: memoryMiB,
    );
  }

  Future<void> _setDiscPlan(DiscBufferPlan plan) async {
    final native = player.platform;
    if (_disposed || _disc == null || native is! NativePlayer) return;
    final previous = _appliedDiscPlan;
    final previousOptions = _discAppliedOptions;
    final options = {
      ...plan.options,
      'cache-secs': '${plan.fast ? 10 : _readAhead.seconds}',
    };
    try {
      for (final option in changedDiscOptions(
        previousOptions,
        options,
      ).entries) {
        if (_disposed) return;
        await native.setProperty(option.key, option.value);
      }
      if (_disposed) return;
      if (previous?.tier != plan.tier) _disc!.setSpeed(plan.tier);
      _appliedDiscPlan = plan;
      _discAppliedOptions = options;
    } catch (_) {
      if (!_disposed && previous != null) {
        try {
          for (final option in (previousOptions ?? previous.options).entries) {
            await native.setProperty(option.key, option.value);
          }
          _disc?.setSpeed(previous.tier);
        } catch (_) {
          _failPlayback('原盘缓存参数调整失败，原参数也未能恢复');
        }
      }
      rethrow;
    }
  }

  Future<void> _beginFastBuffer(String reason) async {
    if (!_usesBufferPolicy || _disposed) return;
    _cancelBufferPhase();
    _bufferPhase.begin();
    if (_disc == null) {
      _streamBuffer.beginFast(preserveRecovery: reason != '开播');
    }
    if (_disc != null) {
      await _setDiscPlan(await _discPlan(_speed, fast: true));
    } else {
      await _streamBuffer.configure(_speed, fast: true);
    }
    log?.add(LogArea.player, '播放缓存阶段：$reason；倍速=$_speed；$_cacheDescription');
  }

  void _updatePersistentReadAhead() {
    if (_disposed ||
        (_bufferPhase.fast && !phoneViewport) ||
        !_readAheadAllowed) {
      return;
    }
    final reader = _cachedTransport?.reader;
    if (reader != null) {
      reader.configureAhead(
        _readAhead.bytes(total: reader.total, duration: _cacheDuration),
      );
    }
    _disc?.configurePersistentReadAhead(_readAhead.seconds);
  }

  void _armBufferPhase() {
    if (!_usesBufferPolicy || _disposed) return;
    _bufferPhase.arm();
    _bufferPhaseTimer?.cancel();
    _bufferPhaseTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      unawaited(_probeBufferPhase());
    });
  }

  void _cancelBufferPhase() {
    _discCacheRetention.cancel();
    _bufferPhaseTimer?.cancel();
    _bufferPhaseTimer = null;
    _bufferPhase.cancel();
  }

  Future<void> _probeBufferPhase() async {
    final native = player.platform;
    if (_disposed ||
        _lastFailure != null ||
        !_usesBufferPolicy ||
        !_bufferPhase.fast ||
        !_bufferPhase.armed ||
        _bufferPhaseProbeBusy ||
        _bufferPromotionQueued ||
        native is! NativePlayer) {
      return;
    }
    final epoch = _bufferPhase.epoch;
    _bufferPhaseProbeBusy = true;
    try {
      final output = await _readVideoOutput();
      // A phone may already have a real frame while MPV waits for its initial
      // cushion. Start the existing bounded persistent read-ahead at that point,
      // rather than waiting for that very cache pause to finish first.
      if (phoneViewport &&
          output.ready &&
          !output.seeking &&
          !_runtimePosition.settling) {
        _updatePersistentReadAhead();
      }
      final cache = await native
          .getProperty('paused-for-cache')
          .timeout(const Duration(milliseconds: 600));
      if (_disposed ||
          _lastFailure != null ||
          !_bufferPhase.canPromote(
            sampleEpoch: epoch,
            outputReady: output.ready,
            buffering: player.state.buffering,
            cachePaused: cache != 'no',
            seeking:
                output.seeking ||
                _runtimePosition.settling ||
                _runtimeRepairBusy,
          )) {
        return;
      }
      _bufferPromotionQueued = true;
      try {
        await _rates.run(() async {
          if (_disposed ||
              _lastFailure != null ||
              epoch != _bufferPhase.epoch ||
              !_bufferPhase.fast ||
              player.state.buffering) {
            return;
          }
          // Read the latest selected rate inside the same queue as menu/hold
          // changes and seeks. Never pause/play or reopen the media here.
          final plan = _disc != null
              ? await _discPlan(_speed, fast: false)
              : null;
          if (_disposed ||
              _lastFailure != null ||
              epoch != _bufferPhase.epoch ||
              player.state.buffering) {
            return;
          }
          if (plan != null) {
            await _setDiscPlan(plan);
          } else {
            await _streamBuffer.configure(_speed, fast: false);
          }
          if (_disposed || epoch != _bufferPhase.epoch) return;
          _readAhead.speed(_speed, retainPeak: _disc != null);
          _bufferPhase.complete(epoch);
          _updatePersistentReadAhead();
          _bufferPhaseTimer?.cancel();
          log?.add(
            LogArea.player,
            '播放缓存阶段：视频输出已就绪；倍速=$_speed；$_cacheDescription',
          );
        });
      } catch (_) {
        if (!_disposed && epoch == _bufferPhase.epoch) {
          _bufferPhase.promotionFailed = true;
          _bufferPhaseTimer?.cancel();
          log?.add(
            LogArea.player,
            '倍速缓存扩展失败，保留已恢复的缓存参数；可用切速重新调整',
            level: LogLevel.warning,
          );
        }
      } finally {
        _bufferPromotionQueued = false;
      }
    } catch (_) {
      // A missing read-only sample is not first-frame evidence. The existing
      // startup, seek, buffer and decoder deadlines remain authoritative.
    } finally {
      _bufferPhaseProbeBusy = false;
    }
  }

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

  @override
  Future<void> subtitle(TrackOption track) async {
    final native = player.platform;
    if (native is! NativePlayer || _disposed) throw const AppFailure('播放会话已关闭');
    final load = _loadSerial;
    ++_subtitlePlacementGeneration;
    bool active() => !_disposed && load == _loadSerial;
    try {
      await protectSubtitleSwitch(
        read: native.getProperty,
        restore: (key, value) async {
          if (!active()) throw const AppFailure('字幕操作已取消');
          if (key == 'sid') {
            await player.setSubtitleTrack(SubtitleTrack(value, null, null));
          } else {
            await native.setProperty(key, value);
          }
        },
        apply: () => _applySubtitle(track, native, active),
        active: active,
      );
    } finally {
      if (active()) await _refreshTracks();
    }
  }

  Future<void> _applySubtitle(
    TrackOption track,
    NativePlayer native,
    bool Function() active,
  ) async {
    if (!active()) throw const AppFailure('字幕操作已取消');
    Future<void> select(SubtitleTrack value) async {
      // media_kit clears its current text cue before setting sid. MPV keeps
      // the same track unchanged, so sub-text need not emit again until the
      // next cue. Preserve that cue when confirming an already selected ID.
      // Off/auto and newly added files retain their existing reset semantics.
      final id = int.tryParse(value.id);
      final same =
          id != null &&
          id > 0 &&
          await native
                  .getProperty('sid')
                  .timeout(const Duration(milliseconds: 600)) ==
              value.id;
      if (!active()) throw const AppFailure('字幕操作已取消');
      if (!same) await player.setSubtitleTrack(value);
    }

    String? addedAddress;
    final saved = _externalIds[track.id];
    if (saved != null) {
      await select(SubtitleTrack(saved, track.title, track.language));
    } else if (track.value case ExternalSubtitle(:final route)) {
      final file = await _subtitleFiles.load(track.id, route, track.codec);
      if (!active()) throw const AppFailure('字幕操作已取消');
      final address = file.uri.toString();
      _subtitleFilePaths.addAll([file.path, address]);
      addedAddress = address;
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          address,
          title: track.title,
          language: track.language,
        ),
      );
    } else if (track.value case LocalSubtitle(:final path)) {
      final address = Uri.file(path).toString();
      _subtitleFilePaths.addAll([path, address]);
      addedAddress = address;
      await player.setSubtitleTrack(
        SubtitleTrack.uri(
          address,
          title: track.title,
          language: track.language,
        ),
      );
    } else {
      await select(track.value as SubtitleTrack);
    }
    if (!active()) throw const AppFailure('字幕操作已取消');
    final actual = await native.getProperty('sid');
    if (addedAddress != null) {
      final count =
          int.tryParse(await native.getProperty('track-list/count')) ?? 0;
      var confirmed = false;
      for (var i = 0; i < count && i < 512; i++) {
        if (await native.getProperty('track-list/$i/id') == actual &&
            await native.getProperty('track-list/$i/type') == 'sub' &&
            await native.getProperty('track-list/$i/external-filename') ==
                addedAddress) {
          confirmed = true;
          break;
        }
      }
      if (!confirmed) throw const AppFailure('MPV 未确认外挂字幕加载，请重试');
      _externalIds[track.id] = actual;
    } else if (actual != (saved ?? track.id) && track.id != 'auto') {
      throw const AppFailure('MPV 未确认字幕切换，请重试');
    }
    // Preserve the existing Flutter text subtitle renderer. Bitmap subtitles
    // have no sub-text; render only those through MPV's existing video output.
    final visible = track.bitmap && actual != 'no' ? 'yes' : 'no';
    if (!active()) throw const AppFailure('字幕操作已取消');
    await native.setProperty('sub-visibility', visible);
    if (await native.getProperty('sub-visibility') != visible) {
      throw const AppFailure('MPV 未确认字幕显示设置，请重试');
    }
    await _applySubtitleLayoutForTrack(track, actual, native, active);
    log?.add(
      LogArea.player,
      '字幕显示核对：轨道已选择=${actual != "no"}；类型=${track.bitmap ? "图像" : "文字"}；原生图像显示=$visible；部分台词是否显示仍需核对实际字幕事件',
    );
  }

  Future<void> _applySubtitleLayoutForTrack(
    TrackOption track,
    String actual,
    NativePlayer native,
    bool Function() active,
  ) async {
    if (!_screenCanvas || actual == 'no') return;
    final discEmbedded =
        _disc?.selected != null &&
        !track.external &&
        track.value is! ExternalSubtitle &&
        track.value is! LocalSubtitle &&
        !_externalIds.values.contains(actual) &&
        _trackMetadata['sub:$actual']?.external != true;
    if (discEmbedded == _subtitleDiscEmbedded) return;
    await writeMpvSubtitleLayout(
      scope: discEmbedded
          ? SubtitlePositionScope.discEmbedded
          : SubtitlePositionScope.regular,
      position: discEmbedded ? _discSubtitlePosition : _regularSubtitlePosition,
      read: native.getProperty,
      write: native.setProperty,
      active: active,
    );
    if (!active()) throw const AppFailure('字幕操作已取消');
    _selectSubtitlePlacement(discEmbedded);
    emit();
  }

  NativePlayer _adjustmentPlayer() {
    final native = player.platform;
    if (_disposed || _opening || native is! NativePlayer || native.disposed) {
      throw const AppFailure('播放器尚未就绪');
    }
    return native;
  }

  @override
  Future<List<PlaybackChapter>> readChapters({
    required bool Function() allowed,
  }) {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final disc = _disc;
    final title = disc?.selected;
    return readAvailableChapters(
      read: (key) => native.getProperty(key, waitForInitialization: false),
      active: () =>
          allowed() &&
          !_disposed &&
          !_opening &&
          serial == _loadSerial &&
          identical(_disc, disc) &&
          identical(disc?.selected, title),
      duration: snapshot.duration,
      origin: 'mpv:$serial',
      discTicks: title == null ? null : List.of(title.chapters),
      discDurationTicks: title?.duration,
      discOrigin: title == null ? null : 'disc:${disc!.id}:${title.playlist}',
    );
  }

  @override
  Future<Duration> readSubtitleDelay({required bool Function() allowed}) {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    return readMpvSubtitleDelay(
      read: (key) => native.getProperty(key, waitForInitialization: false),
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
    );
  }

  @override
  Future<Duration> setSubtitleDelay(
    Duration value, {
    required bool Function() allowed,
  }) {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    return writeMpvSubtitleDelay(
      value: value,
      read: (key) => native.getProperty(key, waitForInitialization: false),
      write: (key, value) =>
          native.setProperty(key, value, waitForInitialization: false),
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
    );
  }

  @override
  Future<double> readPictureBrightness({
    required bool Function() allowed,
  }) async {
    _adjustmentPlayer();
    if (!allowed() || _disposed || _opening) {
      throw const AppFailure('播放会话已改变');
    }
    return _shadow.picture;
  }

  @override
  Future<double> setPictureBrightness(
    double value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final dolby =
        useDolbyEnhancement(_noticeDecoded, 'gpu-next') &&
        await native.getProperty('current-vo') == 'gpu-next';
    bool active() =>
        allowed() && !_disposed && !_opening && serial == _loadSerial;
    final confirmation = dolby
        ? DolbyEnhancementConfirmation(
            read: native.getProperty,
            active: active,
            renderFault: () => _enhancementRenderFault,
          )
        : null;
    await _shadow.set(
      _shadow.value,
      pictureBrightness: value,
      read: (key) => native.getProperty(key, waitForInitialization: dolby),
      write: (key, value) =>
          native.setProperty(key, value, waitForInitialization: dolby),
      active: () =>
          allowed() && !_disposed && !_opening && serial == _loadSerial,
      dolbyInplace: dolby,
      p7Sdr: _noticeDecoded['dolby-vision-profile'] == '7',
      prepareConfirmation: confirmation?.prepare,
      confirm: confirmation?.confirm,
    );
    final actual = _shadow.picture;
    log?.add(LogArea.player, '整体亮度增强：$actual；统一线性RGB增益；仅当前文件，HDR/杜比输出方式保持');
    return actual;
  }

  @override
  Future<double> readSubtitlePosition({
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final generation = _subtitlePlacementGeneration;
    if (!_subtitleAutomatic && _initialSubtitlePosition != null) {
      if (!allowed() || _disposed || _opening) {
        throw const AppFailure('播放会话已改变');
      }
      return _initialSubtitlePosition!;
    }
    if (_subtitleAutomatic &&
        !player.state.subtitle.any((line) => line.trim().isNotEmpty)) {
      double? measured;
      try {
        measured = double.tryParse(
          await native.getProperty('yingyu-subtitle-position'),
        );
      } catch (_) {
        // No active bitmap composition is an unknown baseline, not screen 0%.
      }
      if (!allowed() ||
          _disposed ||
          _opening ||
          serial != _loadSerial ||
          generation != _subtitlePlacementGeneration) {
        throw const AppFailure('播放会话已改变');
      }
      if (measured != null &&
          measured.isFinite &&
          measured >= 0 &&
          measured <= 100) {
        _subtitleDefaultPosition = 100 - measured;
      }
      if (_subtitleDefaultPosition == null) {
        throw const SubtitlePositionPending();
      }
      return _subtitleDefaultPosition!;
    }
    final actual = await readMpvSubtitlePosition(
      read: native.getProperty,
      active: () =>
          allowed() &&
          !_disposed &&
          !_opening &&
          serial == _loadSerial &&
          generation == _subtitlePlacementGeneration,
    );
    return _subtitleAutomatic &&
            !_subtitleDiscEmbedded &&
            _subtitleDefaultPosition != null &&
            player.state.subtitle.any((line) => line.trim().isNotEmpty)
        ? _subtitleDefaultPosition!
        : actual;
  }

  @override
  Future<double> setSubtitlePosition(
    double value, {
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final generation = _subtitlePlacementGeneration;
    bool active() =>
        allowed() &&
        !_disposed &&
        !_opening &&
        serial == _loadSerial &&
        generation == _subtitlePlacementGeneration;
    await writeMpvSubtitleLayout(
      scope: _subtitleDiscEmbedded
          ? SubtitlePositionScope.discEmbedded
          : SubtitlePositionScope.regular,
      position: value,
      read: native.getProperty,
      write: native.setProperty,
      active: active,
    );
    if (!active()) throw const AppFailure('播放会话已改变');
    _subtitleAutomatic = false;
    _initialSubtitlePosition = value;
    if (_subtitleDiscEmbedded) {
      _discSubtitlePosition = value;
    } else {
      _regularSubtitlePosition = value;
    }
    _subtitleViewConfiguration = SubtitleViewConfiguration(
      alignment: Alignment(0, 1 - value / 50),
    );
    emit();
    return value;
  }

  @override
  Future<double> resetSubtitlePosition({
    required bool Function() allowed,
  }) async {
    final native = _adjustmentPlayer();
    final serial = _loadSerial;
    final generation = _subtitlePlacementGeneration;
    bool active() =>
        allowed() &&
        !_disposed &&
        !_opening &&
        serial == _loadSerial &&
        generation == _subtitlePlacementGeneration;
    await writeMpvSubtitleLayout(
      scope: _subtitleDiscEmbedded
          ? SubtitlePositionScope.discEmbedded
          : SubtitlePositionScope.regular,
      read: native.getProperty,
      write: native.setProperty,
      active: active,
    );
    if (!active()) throw const AppFailure('播放会话已改变');
    _subtitleAutomatic = true;
    _initialSubtitlePosition = null;
    if (_subtitleDiscEmbedded) {
      _discSubtitlePosition = null;
    } else {
      _regularSubtitlePosition = null;
    }
    _subtitleViewConfiguration = const SubtitleViewConfiguration();
    emit();
    return readSubtitlePosition(allowed: allowed);
  }

  @override
  Future<void> dispose() async {
    stopDiagnostics();
    ++_playIntent;
    await _latency?.close();
    _latencyHttp = null;
    await _audioDucking.close();
    _phoneFit?.dispose();
    await _stopPacketTrace();
    _audioDecode.cancel();
    _hardwareFallback.cancel();
    _dolbyRecovery.cancel();
    _disposed = true;
    await _openingLogs?.close();
    _openingLogs = null;
    await _screenFit?.close();
    try {
      await _hdr.close();
      if (nativeHdr) {
        log?.add(LogArea.player, 'HDR 退出窗口已清理；${await video.nativeHdrStatus}');
      }
    } catch (_) {
      log?.add(LogArea.player, 'HDR 输出随播放器结束释放', level: LogLevel.warning);
    }
    await _rates.run(() async {});
    final native = player.platform;
    if (native is NativePlayer && _dolbyPreloadedHook != null) {
      native.onPreloadedHooks.remove(_dolbyPreloadedHook);
    }
    _rateProbe.cancel();
    _cancelBufferPhase();
    ++_runtimeEpoch;
    _runtimeWatch.reset();
    _videoLoss.reset();
    _discClockFault.clear();
    _decoderRecovery.cancel();
    _discTimer?.cancel();
    ++_loadSerial;
    _videoTimer?.cancel();
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    await _origin?.close();
    await _disc?.close();
    await _cachedTransport?.close();
    _subtitleFiles.cancel();
    await player.dispose();
    await _subtitleFiles.close();
    await updates.close();
    await failures.close();
  }
}

String audioTrackLabel(AudioTrack track) {
  final codec = switch (track.codec?.toLowerCase()) {
    'ac3' => 'Dolby Digital',
    'eac3' => 'Dolby Digital Plus',
    'truehd' => 'Dolby TrueHD',
    'dts' => 'DTS',
    final value? => value.toUpperCase(),
    _ => '',
  };
  return [
    track.title ?? '音轨 ${track.id}',
    ?track.language,
    if (codec.isNotEmpty) codec,
    if (track.channelscount != null) '${track.channelscount} 声道',
  ].where((v) => v.isNotEmpty).join(' · ');
}
