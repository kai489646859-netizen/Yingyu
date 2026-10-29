import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../core/emby.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/log.dart';
import '../core/accounts.dart';
import '../core/subtitle_document.dart';
import '../core/progress.dart';
import 'episode_continuity.dart';
import 'backend.dart';
import 'first_hop_probe.dart';
import 'tracks.dart';
import 'track_selection.dart';
import 'position_guard.dart';
import 'observation.dart';
import 'rate_requests.dart';
import 'byte_cache.dart';
import 'cache_policy.dart';
import 'playback_adjustments.dart';
import 'picture_brightness.dart';
import 'shadow_enhancement.dart';
import 'audio_balance.dart';
import 'opening_metadata.dart';
import 'subtitle_position_memory.dart';
export 'observation.dart' show SpeedChangeSource, SeekSource, PauseSource;

class PlaybackSession extends ChangeNotifier {
  PlaybackSession({
    required this.api,
    required this.store,
    required this.item,
    required this.backend,
    this.sourceId,
  });
  final EmbyClient api;
  final AppStore store;
  final MediaItem item;
  final String? sourceId;
  final PlayerBackend backend;
  SubtitleViewport _subtitleViewport = SubtitleViewport.tablet;
  bool _subtitleViewportConfigured = false;
  SubtitlePositionTarget? _subtitlePositionTarget;
  bool _subtitlePositionsBound = false;
  final _subtitlePositionOwners = <SubtitlePositionScope, Object>{};
  void configureSubtitleViewport({required bool phone}) {
    if (ready || closed || _subtitleViewportConfigured) return;
    _subtitleViewportConfigured = true;
    _subtitleViewport = phone
        ? SubtitleViewport.phone
        : SubtitleViewport.tablet;
    final currentAccount = api.session;
    if (currentAccount != null) {
      _configureSubtitlePositions(currentAccount, item);
    }
  }

  String get subtitlePositionMemoryLabel =>
      _subtitlePositionTarget?.season == true
      ? '本季'
      : (currentMetadata.type.isEmpty ? item.type : currentMetadata.type) ==
            'Episode'
      ? '本集'
      : '本片';

  void _releaseSubtitlePositionOwners() {
    final target = _subtitlePositionTarget;
    if (target != null) {
      for (final entry in _subtitlePositionOwners.entries) {
        store.subtitlePositions.release(
          _subtitleViewport,
          entry.value,
          scope: entry.key,
          resource: target.key,
        );
      }
    }
    _subtitlePositionOwners.clear();
  }

  void _configureSubtitlePositions(Session currentAccount, MediaItem detail) {
    final target = SubtitlePositionTarget.resolve(currentAccount, detail);
    if (_subtitlePositionsBound &&
        _subtitlePositionTarget?.key == target?.key) {
      return;
    }
    _releaseSubtitlePositionOwners();
    _subtitlePositionTarget = target;
    _subtitlePositionsBound = true;
    for (final scope in SubtitlePositionScope.values) {
      if (target != null) {
        _subtitlePositionOwners[scope] = store.subtitlePositions.claim(
          _subtitleViewport,
          scope: scope,
          resource: target.key,
        );
      }
    }
    final control = backend;
    if (control is InitialSubtitlePositionBackend) {
      (control as InitialSubtitlePositionBackend).configureSubtitlePosition(
        target == null
            ? null
            : store.subtitlePositions.read(
                _subtitleViewport,
                resource: target.key,
              ),
      );
    }
    if (control is ScopedSubtitlePositionBackend) {
      (control as ScopedSubtitlePositionBackend).configureDiscSubtitlePosition(
        target == null
            ? null
            : store.subtitlePositions.read(
                _subtitleViewport,
                scope: SubtitlePositionScope.discEmbedded,
                resource: target.key,
              ),
      );
    }
  }

  // Only natural automatic episode continuity may merge an explicitly enabled
  // intro rule into the initial position. Manual opens keep their old policy.
  bool skipOpeningIntro = false;
  ({Duration from, Duration to})? openingIntro;
  PlaybackRoute? route;
  TrackSelection? trackSelection;
  EpisodeContinuity? _continuity;
  double _continuitySpeed = 1;
  EpisodeContinuity? get continuitySnapshot {
    final series = EpisodeContinuity.seriesOf(currentMetadata);
    if (series == null) return null;
    return EpisodeContinuity(
      account: accountKey(account),
      series: series,
      speed: _continuitySpeed,
      choices: trackSelection?.continuityChoices ?? const {},
    );
  }

  final _externalSubtitles = <TrackOption>[];
  final _manualSubtitles = <SubtitleDocument>[];
  int _manualSubtitleBytes = 0;
  Future<void> attachSubtitle(SubtitleDocument document) async {
    if (!_adjustmentsAllowed) {
      await document.close();
      throw const AppFailure('播放会话已改变');
    }
    try {
      final bytes = await document.file.length();
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      if (bytes <= 0 ||
          bytes > 64 * 1024 * 1024 ||
          _manualSubtitles.length >= 16 ||
          _manualSubtitleBytes + bytes > 128 * 1024 * 1024) {
        throw const AppFailure('本次外挂字幕已达容量上限，请重新播放后导入');
      }
      final track = TrackOption(
        'manual-${_manualSubtitles.length + 1}',
        document.title,
        LocalSubtitle(document.path),
        title: document.title,
        codec: document.codec,
        language: document.language,
        external: true,
      );
      _manualSubtitles.add(document);
      _manualSubtitleBytes += bytes;
      _externalSubtitles.add(track);
      changed();
      // This explicit file belongs to this episode only; no future background
      // lookup, file path memory or inherited online choice is created.
      await chooseTrack(
        true,
        trackOptions(true).firstWhere((value) => value.id == track.id),
      );
    } catch (_) {
      if (!_manualSubtitles.contains(document)) await document.close();
      rethrow;
    }
  }

  List<TrackOption> trackOptions(bool subtitles) {
    final tracks = subtitles ? backend.subtitleTracks : backend.audioTracks;
    if (!subtitles) return tracks;
    final externalIds = _externalSubtitles.map((t) => t.id).toSet();
    return [
          ...tracks.where((t) => !externalIds.contains(t.id)),
          ..._externalSubtitles,
        ]
        .map((track) => subtitleMetadata(track, route?.streams ?? const []))
        .toList();
  }

  String? selectedTrack(bool subtitles) => backend is TrackStateBackend
      ? subtitles
            ? (backend as TrackStateBackend).selectedSubtitleId
            : (backend as TrackStateBackend).selectedAudioId
      : null;
  String get secondaryId => backend is MpvBackend
      ? (backend as MpvBackend).secondarySubtitleId
      : 'no';
  List<TrackOption> get secondaryOptions => [
    const TrackOption('no', '关闭副字幕', 'no'),
    ...trackOptions(true).where(
      (t) =>
          !trackOptions(
            true,
          ).any((main) => main.id == selectedTrack(true) && main.bitmap) &&
          !t.control &&
          !t.external &&
          !t.bitmap &&
          t.id != selectedTrack(true),
    ),
  ];
  int _secondaryIntent = 0;
  Future<void> chooseSecondary(TrackOption track) async {
    final intent = ++_secondaryIntent;
    if (!_adjustmentsAllowed || backend is! MpvBackend) return;
    if (!secondaryOptions.any((t) => t.signature == track.signature)) {
      throw const AppFailure('字幕轨道已改变');
    }
    await (backend as MpvBackend).secondarySubtitle(track);
    if (!_adjustmentsAllowed || intent != _secondaryIntent) return;
    final series = item.data['SeriesId']?.toString();
    await store.saveTrackChoice(
      account,
      [
        'secondary:item:${item.id}',
        if (series != null) 'secondary:series:$series',
      ],
      true,
      TrackChoice.fromTrack(track),
    );
    changed();
  }

  Future<void> chooseTrack(bool subtitles, TrackOption track) async {
    if (!closed && ready) {
      if (subtitles &&
          backend is MpvBackend &&
          (track.id == 'no' || track.id == secondaryId || track.bitmap)) {
        await chooseSecondary(const TrackOption('no', '关闭副字幕', 'no'));
      }
      await trackSelection?.choose(
        subtitles,
        track,
        remember: track.value is! LocalSubtitle,
      );
      if (!closed) {
        unawaited(
          report(
            'Progress',
            eventName: subtitles ? 'SubtitleTrackChange' : 'AudioTrackChange',
          ),
        );
      }
    }
  }

  bool get _adjustmentsAllowed =>
      ready && !closed && api.session == account && error == null;
  bool get hasChapters => backend is PlaybackChapterBackend;
  bool get hasSubtitleDelay => backend is SubtitleDelayBackend;
  bool get hasSubtitlePosition => backend is SubtitlePositionBackend;
  bool get hasPictureBrightness => backend is PictureBrightnessBackend;
  bool get hasShadowEnhancement => backend is ShadowEnhancementBackend;
  bool get hasAudioBalance =>
      store.audioBalanceEnabled && backend is AudioBalanceBackend;
  AudioBalance get audioBalance => backend is AudioBalanceBackend
      ? (backend as AudioBalanceBackend).audioBalance
      : AudioBalance.original;
  String? audioBalanceWarning;
  Future<void> _audioBalanceTail = Future.value();
  Future<void> setAudioBalance(AudioBalance value, {bool remember = true}) {
    final job = _audioBalanceTail.then((_) async {
      final control = backend;
      if (!_adjustmentsAllowed ||
          !store.audioBalanceEnabled ||
          control is! AudioBalanceBackend) {
        throw const AppFailure('当前播放器无法均衡音量');
      }
      final audio = control as AudioBalanceBackend;
      final previous = audio.audioBalance;
      await audio.setAudioBalance(value, allowed: () => _adjustmentsAllowed);
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      try {
        if (remember) await store.setAudioBalance(value);
      } catch (_) {
        if (_adjustmentsAllowed) {
          await audio.setAudioBalance(
            previous,
            allowed: () => _adjustmentsAllowed,
          );
        }
        rethrow;
      }
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      audioBalanceWarning = null;
      changed();
    });
    _audioBalanceTail = job.then<void>((_) {}, onError: (Object _) {});
    return job;
  }

  Future<void> _restoreAudioBalance() async {
    final requested = store.audioBalance;
    if (!hasAudioBalance || requested == AudioBalance.original) return;
    try {
      await setAudioBalance(requested, remember: false);
    } catch (e) {
      if (!_adjustmentsAllowed) return;
      audioBalanceWarning = safeError(e);
      store.log.add(LogArea.player, '音量均衡未恢复：${safeError(e)}');
      changed();
    }
  }

  double get shadowEnhancement => backend is ShadowEnhancementBackend
      ? (backend as ShadowEnhancementBackend).shadowEnhancement
      : 0;
  Future<double> setShadowEnhancement(double value) {
    final job = _pictureTail.then((_) async {
      final control = backend;
      if (!_adjustmentsAllowed || control is! ShadowEnhancementBackend) {
        throw const AppFailure('当前播放器无法调整暗部增强');
      }
      final actual = await (control as ShadowEnhancementBackend)
          .setShadowEnhancement(value, allowed: () => _adjustmentsAllowed);
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      changed();
      return actual;
    });
    _pictureTail = job.then<void>(
      (_) {},
      onError: (Object failure) {
        store.log.add(
          LogArea.player,
          '画面增强失败：${safeError(failure)}',
          level: LogLevel.warning,
        );
      },
    );
    return job;
  }

  Future<double> readPictureBrightness() async {
    final control = backend;
    if (!_adjustmentsAllowed || control is! PictureBrightnessBackend) {
      throw const AppFailure('当前播放器无法调整画面明暗');
    }
    return (control as PictureBrightnessBackend).readPictureBrightness(
      allowed: () => _adjustmentsAllowed,
    );
  }

  Future<void> _pictureTail = Future.value();
  Future<double> setPictureBrightness(double value) {
    final job = _pictureTail.then((_) async {
      final control = backend;
      if (!_adjustmentsAllowed || control is! PictureBrightnessBackend) {
        throw const AppFailure('当前播放器无法调整画面明暗');
      }
      final actual = await (control as PictureBrightnessBackend)
          .setPictureBrightness(value, allowed: () => _adjustmentsAllowed);
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      changed();
      return actual;
    });
    _pictureTail = job.then<void>(
      (_) {},
      onError: (Object failure) {
        store.log.add(
          LogArea.player,
          '画面增强失败：${safeError(failure)}',
          level: LogLevel.warning,
        );
      },
    );
    return job;
  }

  bool? get usesDefaultSubtitlePosition =>
      backend is DefaultSubtitlePositionBackend
      ? (backend as DefaultSubtitlePositionBackend).usesDefaultSubtitlePosition
      : null;
  bool get usesDiscSubtitlePosition =>
      backend is ScopedSubtitlePositionBackend &&
      (backend as ScopedSubtitlePositionBackend).subtitlePositionScope ==
          SubtitlePositionScope.discEmbedded;

  Future<double> readSubtitlePosition() async {
    final control = backend;
    if (!_adjustmentsAllowed || control is! SubtitlePositionBackend) {
      throw const AppFailure('当前播放器无法调整字幕位置');
    }
    final value = await (control as SubtitlePositionBackend)
        .readSubtitlePosition(allowed: () => _adjustmentsAllowed);
    if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
    return value;
  }

  Future<void> _subtitlePositionTail = Future.value();
  Future<double> setSubtitlePosition(double value) =>
      _changeSubtitlePosition(value);
  Future<double> resetSubtitlePosition() => _changeSubtitlePosition(null);
  Future<double> _changeSubtitlePosition(double? value) {
    final job = _subtitlePositionTail.then((_) async {
      final control = backend;
      if (!_adjustmentsAllowed || control is! SubtitlePositionBackend) {
        throw const AppFailure('当前播放器无法调整字幕位置');
      }
      final scope = control is ScopedSubtitlePositionBackend
          ? (control as ScopedSubtitlePositionBackend).subtitlePositionScope
          : SubtitlePositionScope.regular;
      double? actual;
      try {
        actual = value == null && control is DefaultSubtitlePositionBackend
            ? await (control as DefaultSubtitlePositionBackend)
                  .resetSubtitlePosition(allowed: () => _adjustmentsAllowed)
            : await (control as SubtitlePositionBackend).setSubtitlePosition(
                value ?? 0,
                allowed: () => _adjustmentsAllowed,
              );
      } on SubtitlePositionPending {
        // Reset already restored authored layout. Persist automatic mode even
        // if this instant has no subtitle; its geometry stays explicitly unknown.
        if (value != null ||
            control is! DefaultSubtitlePositionBackend ||
            !(control as DefaultSubtitlePositionBackend)
                .usesDefaultSubtitlePosition) {
          rethrow;
        }
      }
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      if (control is ScopedSubtitlePositionBackend &&
          (control as ScopedSubtitlePositionBackend).subtitlePositionScope !=
              scope) {
        throw const AppFailure('字幕轨道已改变');
      }
      final target = _subtitlePositionTarget;
      if (target != null) {
        final owner = _subtitlePositionOwners[scope] ??= store.subtitlePositions
            .claim(_subtitleViewport, scope: scope, resource: target.key);
        await store.subtitlePositions.save(
          _subtitleViewport,
          owner,
          value == null && control is DefaultSubtitlePositionBackend
              ? null
              : actual,
          active: () =>
              _adjustmentsAllowed && _subtitlePositionTarget?.key == target.key,
          scope: scope,
          resource: target.key,
        );
      }
      changed();
      if (actual == null) throw const SubtitlePositionPending();
      return actual;
    });
    _subtitlePositionTail = job.then<void>((_) {}, onError: (Object _) {});
    return job;
  }

  Future<List<PlaybackChapter>> readChapters() async {
    final control = backend;
    if (!_adjustmentsAllowed || control is! PlaybackChapterBackend) {
      throw const AppFailure('当前播放器无法读取章节');
    }
    final result = await (control as PlaybackChapterBackend).readChapters(
      allowed: () => _adjustmentsAllowed,
    );
    if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
    return result;
  }

  Future<void> seekChapter(PlaybackChapter chapter) async {
    final current = await readChapters();
    final selected = current
        .where(
          (item) =>
              item.index == chapter.index &&
              item.start == chapter.start &&
              item.origin == chapter.origin,
        )
        .firstOrNull;
    if (!_adjustmentsAllowed || selected == null) {
      throw const AppFailure('章节已改变，请重新打开面板');
    }
    await seek(selected.start, source: SeekSource.menu);
  }

  Future<Duration> readSubtitleDelay() async {
    final control = backend;
    if (!_adjustmentsAllowed || control is! SubtitleDelayBackend) {
      throw const AppFailure('当前播放器无法调整字幕延迟');
    }
    final result = await (control as SubtitleDelayBackend).readSubtitleDelay(
      allowed: () => _adjustmentsAllowed,
    );
    if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
    return result;
  }

  Future<void> _subtitleDelayTail = Future.value();
  Future<Duration> adjustSubtitleDelay({
    Duration delta = Duration.zero,
    bool reset = false,
  }) {
    final result = _subtitleDelayTail.then((_) async {
      final control = backend;
      if (!_adjustmentsAllowed || control is! SubtitleDelayBackend) {
        throw const AppFailure('当前播放器无法调整字幕延迟');
      }
      final delayed = control as SubtitleDelayBackend;
      final before = await delayed.readSubtitleDelay(
        allowed: () => _adjustmentsAllowed,
      );
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      final actual = await delayed.setSubtitleDelay(
        reset ? Duration.zero : before + delta,
        allowed: () => _adjustmentsAllowed,
      );
      if (!_adjustmentsAllowed) throw const AppFailure('播放会话已改变');
      changed();
      return actual;
    });
    _subtitleDelayTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  int? _streamIndex(bool subtitles) {
    final track = trackOptions(
      subtitles,
    ).where((t) => t.id == selectedTrack(subtitles)).firstOrNull;
    return track == null
        ? null
        : embyTrackIndex(track, subtitles, route!.streams);
  }

  void _prepareTracks(MediaItem detail) {
    final current = route!;
    for (final stream in current.streams.where(
      (s) => s['Type'] == 'Subtitle' && s['IsExternal'] == true,
    )) {
      final raw = stream['DeliveryUrl']?.toString() ?? '';
      if (raw.isEmpty || stream['Index'] is! num) continue;
      final uri = resolveMediaUri(account.base, raw);
      if (!const {'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        continue;
      }
      final id = 'external-${integer(stream['Index'])}';
      final title = '${stream['DisplayTitle'] ?? stream['Title'] ?? ''}';
      final language = '${stream['Language'] ?? ''}';
      final codec = '${stream['Codec'] ?? ''}';
      final address = Uri.parse(raw).hasScheme ? raw : uri.toString();
      _externalSubtitles.add(
        TrackOption(
          id,
          trackLabel(
            id: id,
            language: language,
            title: title,
            codec: codec,
            external: true,
          ),
          ExternalSubtitle(
            PlaybackRoute(
              url: address,
              sourceId: current.sourceId,
              sessionId: current.sessionId,
              headers: const {},
              streams: const [],
              serverBase: account.base,
              sameOriginHeaders: uri.origin == account.base.origin
                  ? Map.fromEntries(
                      api
                          .headers(
                            account.deviceId,
                            token: account.token,
                            userId: account.userId,
                          )
                          .entries
                          .where(
                            (e) => e.key.toLowerCase().startsWith('x-emby-'),
                          ),
                    )
                  : const {},
              diagnosticSecrets: current.diagnosticSecrets,
            ),
          ),
          language: language,
          title: title,
          codec: codec,
          external: true,
          forced: stream['IsForced'] == true,
        ),
      );
    }
    final series = detail.data['SeriesId']?.toString();
    final userData = object(detail.data['UserData']);
    trackSelection = TrackSelection(
      store: store,
      account: account,
      itemScope: 'item:${jsonEncode([detail.id, current.sourceId])}',
      seriesScope:
          detail.type == 'Episode' && series != null && series.isNotEmpty
          ? 'series:$series'
          : null,
      inheritedChoices: _continuity?.choices ?? const {},
      options: trackOptions,
      apply: (subtitles, track) =>
          subtitles ? backend.subtitle(track) : backend.audio(track),
      selected: selectedTrack,
      onChanged: changed,
      active: () => !closed && !_completed,
      serverDefault: (s) =>
          s ? current.defaultSubtitleIndex : current.defaultAudioIndex,
      serverOption: (s, index) =>
          embyTrackOption(index, s, trackOptions(s), current.streams),
      serverIndex: (s, track) => embyTrackIndex(track, s, current.streams),
      // PlaybackInfo defaults can also be generated by general account rules.
      // A never-watched item retains our simplified-subtitle/film-audio policy.
      restoreServerSelection:
          detail.resume > Duration.zero ||
          integer(userData['PlayCount']) > 0 ||
          userData['LastPlayedDate'] != null,
    );
    if (backend is MpvBackend) {
      (backend as MpvBackend).openingSecondaryChoice = (parsed) {
        final remembered =
            store.trackChoice(account, 'secondary:item:${detail.id}', true) ??
            (series == null
                ? null
                : store.trackChoice(account, 'secondary:series:$series', true));
        return remembered?.resolve(
          parsed.where((t) => !t.external && !t.bitmap).toList(),
          sameItem: false,
        );
      };
    }
    if (backend is InitialSubtitleBackend) {
      (backend as InitialSubtitleBackend).openingSubtitleChoice = (parsed) {
        if (closed) return null;
        final options = [
          ...parsed.map((t) => subtitleMetadata(t, current.streams)),
          ..._externalSubtitles,
        ];
        return trackSelection?.openingSubtitle(options);
      };
    }
  }

  bool loading = true, ready = false, closed = false, background = false;
  String? error, syncWarning;
  double speed = 1;
  double? _holdRestoreSpeed;
  bool get holdingSpeed => _holdRestoreSpeed != null;
  double? get pendingSpeed => _rateRequests.pending;
  late final _rateRequests = RateRequests(
    current: () => speed,
    apply: _applySpeed,
    changed: changed,
    record: _recordAction,
  );

  Future<void> beginSpeedHold(double value) {
    if (!canChangeSpeed) return Future.value();
    _holdRestoreSpeed ??= _rateRequests.target;
    return setSpeed(value, source: SpeedChangeSource.holdStart);
  }

  Future<void> endSpeedHold({
    SpeedChangeSource source = SpeedChangeSource.holdRestore,
  }) {
    final restore = _holdRestoreSpeed;
    _holdRestoreSpeed = null;
    changed();
    if (restore != null) return setSpeed(restore, source: source);
    return source == SpeedChangeSource.holdRestore
        ? _rateRequests.flush()
        : Future.value();
  }

  final _position = PlaybackPositionGuard();
  Duration get position => _position.value;
  bool _positionWarning = false, _seeking = false;
  final _loadingClock = Stopwatch();
  String? _loadingKind;
  late final _diagnosticId = store.log.nextRequest('播放');
  final _sessionClock = Stopwatch();
  int _speedChanges = 0, _speedFailures = 0, _seekCommands = 0;
  int _bufferEvents = 0, _bufferWaitMs = 0;

  String get _diagnosticState {
    final state = backend.snapshot;
    return '位置=${position.inMilliseconds} ms；倍速=$speed；'
        '请求播放=${state.playing}；缓冲=${state.buffering}；后台=$background；'
        '${backend is PlaybackDiagnosticState ? (backend as PlaybackDiagnosticState).diagnosticState : "后端采样=未提供"}';
  }

  void _recordAction(String message, {LogLevel level = LogLevel.info}) {
    store.log.add(
      LogArea.player,
      '$_diagnosticId；会话经过=${_sessionClock.elapsedMilliseconds} ms；'
      '$message；$_diagnosticState',
      level: level,
    );
  }

  String get openingMessage => switch (_loadingKind) {
    '读取最新进度与媒体资料' => '正在读取影片信息',
    '准备原文件播放地址' => '正在获取播放地址',
    '准备音轨与字幕' => '正在准备音轨与字幕',
    '开始播放' => '正在开始播放',
    _ => backend.snapshot.openingStage,
  };

  void _beginLoading(String kind) {
    if (_loadingKind == kind) return;
    _endLoading('阶段切换');
    _loadingKind = kind;
    _loadingClock
      ..reset()
      ..start();
    if (kind == '播放缓冲') _bufferEvents++;
    store.log.add(
      LogArea.player,
      '资源加载开始：阶段=$kind；$_diagnosticId；$_diagnosticState',
    );
    if (loading && !closed) changed();
  }

  void _endLoading(String result) {
    final kind = _loadingKind;
    if (kind == null) return;
    if (kind == '播放缓冲') _bufferWaitMs += _loadingClock.elapsedMilliseconds;
    store.log.add(
      LogArea.player,
      '资源加载结束：阶段=$kind；结果=$result；等待=${_loadingClock.elapsedMilliseconds} ms；'
      '$_diagnosticId；$_diagnosticState',
    );
    _loadingKind = null;
    _loadingClock.stop();
  }

  late final Session account = api.session!;
  Timer? _timer;
  StreamSubscription? _stateSub, _errorSub;
  Future<void> _reports = Future.value();
  bool _reporting = false, _started = false, _wasBuffering = false;
  Duration _mediaDuration = Duration.zero;
  MediaItem? _serverBaseline;
  bool _completed = false;
  bool _restartDisplayIntent = false;
  ({int command, PlaybackSnapshot state})? _seekCompletion;
  bool _endReported = false;
  int _lastProgressRecovery = -1;
  DateTime? _lastPendingRetry;
  String? _completionWarning;
  Future<void> _completionSave = Future.value();
  bool get completed => _completed;
  bool get seeking => _seeking;
  MediaItem get currentMetadata => _serverBaseline ?? item;
  Future<void>? _closing;
  void changed() {
    if (!closed) notifyListeners();
  }

  void _confirmCompleted(PlaybackSnapshot state) {
    if (_completed || !state.completed || !_nearEnd) return;
    _completed = true;
    _restartDisplayIntent = false;
    // Persist immediately; do not wait behind a slow HTTP check-in.
    _completionSave = store.completions
        .remember(account, _serverBaseline ?? item, _mediaDuration)
        .catchError((Object e) {
          syncWarning = '已看记录本机保存失败：${safeError(e)}';
          _completionWarning = syncWarning;
          store.log.add(LogArea.progress, syncWarning!, level: LogLevel.error);
        });
    store.log.add(LogArea.player, '正常片尾已确认；保留播放页面，开始核对本集已看记录');
  }

  Future<void> open({
    bool fromBeginning = false,
    EpisodeContinuity? continuity,
    OpeningMetadata? metadata,
  }) async {
    _sessionClock.start();
    if (!_subtitleViewportConfigured) configureSubtitleViewport(phone: false);
    final watch = Stopwatch()..start();
    var phase = '读取最新进度与媒体资料';
    store.log.add(LogArea.player, '开始一次播放；${fromBeginning ? '从头播放' : '允许续播'}');
    _recordAction('播放会话开始；续播允许=${!fromBeginning}');
    _beginLoading(phase);
    try {
      if (api.session == null) throw const AppFailure('登录已过期，请重新登录');
      // Capture before the first await; an account switch must cancel this open.
      final openingAccount = account;
      final detail = metadata == null
          ? await api.detail(item.id)
          : await metadata.take(api, item.id);
      if (closed) return;
      if (api.session != openingAccount) {
        throw const AppFailure('账户已切换，请重新打开影片');
      }
      store.log.add(
        LogArea.player,
        '开播耗时：最新资料=${watch.elapsedMilliseconds} ms',
      );
      if (metadata != null) {
        store.log.add(
          LogArea.player,
          '开播资料衔接：本次请求=${metadata.requestMilliseconds} ms；'
          '就绪后等待=${metadata.readyAgeMilliseconds} ms；使用提前准备=${metadata.prepared && !metadata.refreshed}；重新核对=${metadata.refreshed}；未预取媒体',
        );
      }
      _mediaDuration = detail.duration;
      _serverBaseline = detail;
      // Use the already-requested detail before media load. A list item may
      // omit SeasonId; it cannot make the entire season lose its preference.
      _configureSubtitlePositions(
        openingAccount,
        MediaItem({...item.data, ...detail.data}),
      );
      _restartDisplayIntent =
          fromBeginning || store.restartObserved(account, detail);
      _continuity = continuity?.matches(account, detail) == true
          ? continuity
          : null;
      _continuitySpeed = _continuity?.speed ?? 1;
      final resume = store.resume(account, detail);
      _position.reset(fromBeginning ? Duration.zero : resume.position);
      if (skipOpeningIntro && detail.type == 'Episode') {
        final rule = store.personal.resolveSkipRule(account, detail)?.rule;
        if (rule?.autoIntro == true &&
            rule!.introContains(position, detail.duration)) {
          openingIntro = (from: position, to: rule.intro!.end);
          _position.reset(rule.intro!.end);
          store.log.add(LogArea.player, '自动连播：已启用的片头范围合并到首次定位；不预取下一集媒体');
        }
      }
      store.log.add(
        LogArea.progress,
        '续播决策：来源=${fromBeginning ? "从头播放" : resume.reason}；位置=${position.inMilliseconds} ms；服务器=${detail.resume.inMilliseconds} ms',
      );
      phase = '准备原文件播放地址';
      _beginLoading(phase);
      final routeStart = watch.elapsedMilliseconds;
      route = await api.preparePlayback(
        detail,
        sourceId: sourceId,
        start: position,
      );
      if (closed) return;
      if (api.session != openingAccount) {
        throw const AppFailure('账户已切换，请重新打开影片');
      }
      store.log.add(
        LogArea.player,
        '开播耗时：地址准备=${watch.elapsedMilliseconds - routeStart} ms；累计=${watch.elapsedMilliseconds} ms',
      );
      _prepareTracks(detail);
      if (backend is PersistentPlaybackBackend && store.playbackCacheGB != 0) {
        final limit = store.playbackCacheGB;
        // A cold cache index must not delay the first picture. Until it is
        // ready, raw ranges go directly from the source to the player.
        unawaited(
          store.videoCache
              .configure(limit < 0 ? -1 : limit * playbackGiB)
              .catchError((Object _) {
                store.videoCache.warning = '播放缓存暂不可用，继续直接播放';
              }),
        );
        if (closed || api.session != openingAccount) return;
        (backend as PersistentPlaybackBackend).configureCache(
          store.videoCache,
          playbackCacheHash([accountKey(account), detail.id, route!.sourceId]),
          detail.duration,
        );
      }
      _stateSub = backend.changes.listen((state) {
        if (state.duration > Duration.zero) _mediaDuration = state.duration;
        if (ready &&
            _seeking &&
            state.completed &&
            state.duration > Duration.zero &&
            position >= state.duration - const Duration(seconds: 3) &&
            state.position >= state.duration - const Duration(seconds: 3)) {
          // media_kit clears completed after the seek command reply. Preserve
          // a real EOF seen during this intent, before that command cleanup.
          _seekCompletion = (command: _seekCommands, state: state);
        }
        if (ready && !_seeking) {
          if (!_position.accept(state.position, duration: state.duration)) {
            if (!_positionWarning && _position.rejected) {
              store.log.add(
                LogArea.progress,
                '忽略异常播放位置：原始=${state.position.inMilliseconds} ms；'
                '保留=${position.inMilliseconds} ms；没有用户定位，不覆盖续播',
                level: LogLevel.warning,
              );
            }
            _positionWarning = _position.rejected;
          } else {
            _positionWarning = false;
          }
          // A spurious end/reset in the middle must not erase a checkpoint.
          _confirmCompleted(state);
        }
        if (ready && _started && _wasBuffering != state.buffering) {
          _wasBuffering = state.buffering;
          if (state.buffering) {
            _beginLoading('播放缓冲');
            // Complete an already requested decrease, without permitting a
            // new speed choice while buffering. Its caller keeps any error.
            unawaited(_rateRequests.flush().catchError((Object _) {}));
          } else {
            _endLoading('恢复播放');
          }
          unawaited(
            report(
              'Progress',
              eventName: state.buffering ? 'Pause' : 'Unpause',
            ),
          );
        }
        if (_completed && ready && !_endReported) {
          unawaited(report('Stopped'));
        }
        if (ready && !_completed) unawaited(trackSelection?.refresh());
        changed();
      });
      _errorSub = backend.errors.listen((e) {
        _endLoading('播放失败');
        _recordAction('播放错误到达会话：${safeError(e)}', level: LogLevel.error);
        error = safeError(e);
        ready = false;
        loading = false;
        _holdRestoreSpeed = null;
        unawaited(_rateRequests.close());
        _timer?.cancel();
        unawaited(
          backend
              .pause()
              .catchError((Object _) {
                // Keep the original MPV error when its failed backend cannot pause.
              })
              .then((_) {
                if (_started && !closed) {
                  return report('Progress', eventName: 'Pause');
                }
              }),
        );
        changed();
      });
      if (backend is DiscNavigationBackend) {
        (backend as DiscNavigationBackend).forcedDiscKind = store.discKind(
          account,
          item.id,
          route!.sourceId,
        );
        (backend as DiscNavigationBackend).discPlaylist = store.discPlaylist(
          account,
          item.id,
          route!.sourceId,
        );
      }
      phase = '连接媒体与准备画面';
      _beginLoading(phase);
      final mediaStart = watch.elapsedMilliseconds;
      await backend.open(route!, position);
      if (closed || error != null) return;
      final inheritedRate = _continuity?.speed ?? 1;
      if (inheritedRate != 1) {
        await _rateRequests.request(
          inheritedRate,
          SpeedChangeSource.continuity,
        );
        if (closed || error != null) return;
      }
      store.log.add(
        LogArea.player,
        '开播耗时：媒体与画面=${watch.elapsedMilliseconds - mediaStart} ms；累计=${watch.elapsedMilliseconds} ms',
      );
      final prepareTracks =
          backend is OpeningTracksBackend &&
          (backend as OpeningTracksBackend).prepareTracksWhilePaused;
      if (prepareTracks) {
        // Apply initial tracks before the pending HDR decoder refill. A sid
        // refresh must not invalidate the final refill's audio/video queues.
        _beginLoading('准备音轨与字幕');
        await trackSelection?.refresh();
        if (closed || error != null) return;
        _beginLoading('校验播放输出');
        await (backend as OpeningTracksBackend).settleOpeningTracks();
        if (closed || error != null) return;
      }
      ready = true;
      // Track preparation needs readiness internally. Keep the visible opening
      // state until the original first-play transaction has completed.
      // Do not delay or reopen media for subtitle loading. A failed selection
      // has its own visible warning and never replaces a media playback error.
      if (!prepareTracks && _continuity?.choices.isNotEmpty == true) {
        await trackSelection?.refresh();
        if (closed || error != null) return;
      } else if (!prepareTracks) {
        unawaited(trackSelection?.refresh());
      }
      _beginLoading('开始播放');
      if (!background) await backend.play();
      if (closed || error != null) return;
      loading = false;
      _endLoading(background ? '后台暂停' : '已请求播放');
      // An explicitly saved optional audio effect never holds initial play.
      unawaited(_restoreAudioBalance());
      _started = true;
      _wasBuffering = backend.snapshot.buffering;
      if (_wasBuffering) _beginLoading('播放缓冲');
      store.log.add(LogArea.player, '播放已就绪；${background ? '处于后台暂停' : '已请求播放'}');
      if (metadata != null) {
        store.log.add(
          LogArea.player,
          '开播完整衔接：本次播放意图至请求播放=${metadata.elapsedMilliseconds} ms；'
          '后台暂停=$background；缓冲=${backend.snapshot.buffering}；不等于屏幕实测或持续流畅验收',
        );
      }
      unawaited(report(''));
      _timer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (!_reporting) {
          if (_completed) {
            _retryPendingRecords();
          } else {
            unawaited(report('Progress'));
          }
        }
      });
      changed();
    } catch (e) {
      if (!closed) {
        _endLoading('打开失败');
        store.log.add(
          LogArea.player,
          '本次播放未能打开；阶段=$phase；累计=${watch.elapsedMilliseconds} ms',
          level: LogLevel.error,
        );
        loading = false;
        ready = false;
        error = safeError(e);
        changed();
        if (const bool.fromEnvironment('YINGYU_DIAGNOSTICS') &&
            route != null &&
            error!.contains('HTTP 403')) {
          unawaited(
            inspectRejectedRoute(
              route!,
              store.log,
              cancelled: () => closed,
              embyHeaders: api.headers(account.deviceId, token: account.token),
            ),
          );
        }
      }
    }
  }

  Future<void> report(String event, {String eventName = 'TimeUpdate'}) {
    if (!_started || route == null || closed && event != 'Stopped') {
      return Future.value();
    }
    // A pending seek is still reversible. Only its settled result (or an exit
    // with that latest intent) may supersede an earlier completion receipt.
    if (_seeking && event.isNotEmpty && event != 'Stopped') {
      return Future.value();
    }
    final at = position;
    final state = backend.snapshot;
    final paused = !state.playing || state.buffering;
    final completed = _completed;
    final keepZeroDisplay = _restartDisplayIntent && !completed;
    final progressIntent = _seekCommands;
    // A queued progress event can precede a real EOF in this same seek intent.
    // It must not supersede the completion just persisted by the state listener.
    bool currentProgressIntent() =>
        progressIntent == _seekCommands &&
        (completed || !_completed) &&
        (!_seeking || event == 'Stopped');
    bool currentServerIntent() =>
        currentProgressIntent() && api.session == account;
    if (completed) {
      if (_endReported) return _reports;
      _endReported = true;
      event = 'Stopped';
    }
    final duration = state.duration > Duration.zero
        ? state.duration
        : _mediaDuration;
    final rate = speed;
    final audioIndex = _streamIndex(false), subtitleIndex = _streamIndex(true);
    _reports = _reports.then((_) async {
      _reporting = true;
      String? localWarning;
      try {
        if (completed) {
          await _completionSave;
          localWarning = _completionWarning;
        }
        try {
          if (currentProgressIntent()) {
            await store.saveProgress(
              account,
              item.id,
              completed ? Duration.zero : at,
              serverBaseline: _serverBaseline,
              keepZeroDisplay: keepZeroDisplay,
              completed: completed,
              allowed: currentProgressIntent,
            );
          }
        } catch (e) {
          localWarning = [?localWarning, safeError(e)].join('；');
          store.log.add(
            LogArea.progress,
            '本机进度保存失败，继续发送服务器：$localWarning',
            level: LogLevel.warning,
          );
        }
        if (api.session != account) throw const AppFailure('账户已切换，进度保留在本机');
        await api.report(
          event,
          item,
          route!,
          at,
          paused,
          duration: duration,
          rate: rate,
          eventName: eventName,
          audioStreamIndex: audioIndex,
          subtitleStreamIndex: subtitleIndex,
        );
        if (api.session != account) throw const AppFailure('账户已切换，进度保留在本机');
        if (completed && currentServerIntent()) {
          await store.completions.syncOne(
            api,
            account,
            item.id,
            allowed: currentServerIntent,
          );
        }
        if (!currentProgressIntent()) return;
        // A 2xx check-in acknowledges the event; it does not prove that a
        // zero-duration STRM has acquired a usable resume point. Keep the local
        // checkpoint until stopped playback has been read back from Emby.
        if (event == 'Stopped') {
          if (api.session != account) throw const AppFailure('账户已切换，停止核对旧账户进度');
          var saved = await api
              .detail(item.id)
              .timeout(const Duration(seconds: 3));
          if (api.session != account) throw const AppFailure('账户已切换，停止核对旧账户进度');
          if (!currentProgressIntent()) return;
          bool matches(MediaItem value) => completed
              ? object(value.data['UserData'])['Played'] == true &&
                    value.resume == Duration.zero
              : progressMatches(value.resume, at);
          store.log.add(
            LogArea.progress,
            '退出进度核对：上报=${at.inMilliseconds} ms；回读=${saved.resume.inMilliseconds} ms；服务器时长=${saved.duration.inMilliseconds} ms；一致=${matches(saved)}',
          );
          await store.observeProgress(
            account,
            saved,
            completed ? Duration.zero : at,
            allowed: currentServerIntent,
          );
          if (!currentProgressIntent()) return;
          if (!matches(saved) && !completed && api.session == account) {
            store.log.add(
              LogArea.progress,
              '播放事件已接受但续播位置不一致；通过用户进度接口补存一次',
              level: LogLevel.warning,
            );
            await api.saveResume(saved, at);
            if (api.session != account) {
              throw const AppFailure('账户已切换，停止核对旧账户进度');
            }
            if (!currentProgressIntent()) return;
            saved = await api
                .detail(item.id)
                .timeout(const Duration(seconds: 3));
            if (api.session != account) {
              throw const AppFailure('账户已切换，停止核对旧账户进度');
            }
            if (!currentProgressIntent()) return;
            await store.observeProgress(
              account,
              saved,
              at,
              allowed: currentServerIntent,
            );
            if (!currentProgressIntent()) return;
            store.log.add(
              LogArea.progress,
              '补存进度核对：上报=${at.inMilliseconds} ms；回读=${saved.resume.inMilliseconds} ms；一致=${matches(saved)}',
            );
          }
          if (matches(saved)) {
            await store.confirmProgress(
              account,
              item.id,
              completed ? Duration.zero : at,
              allowed: currentServerIntent,
            );
          } else {
            syncWarning = localWarning == null
                ? completed
                      ? 'Emby 已确认看完，但尚未返回零位置，已保留本机从头播放位置'
                      : 'Emby 尚未返回相同进度，已保留本机续播位置'
                : 'Emby 尚未返回相同进度；本机保存也失败：$localWarning';
            store.log.add(
              LogArea.progress,
              syncWarning!,
              level: LogLevel.warning,
            );
            return;
          }
        }
        if (!currentProgressIntent()) return;
        syncWarning = localWarning;
        _retryPendingRecords();
      } catch (e) {
        store.log.add(
          LogArea.progress,
          localWarning == null
              ? '进度同步失败，进度保留在本机'
              : '进度同步与本机保存均失败：$localWarning',
          level: LogLevel.warning,
        );
        syncWarning =
            '进度同步失败：${safeError(e)}${localWarning == null ? "" : "；$localWarning"}';
        if (completed) {
          // The durable receipt is retried when this account reconnects. A
          // failed check-in must never delete it or start a different episode.
          store.log.add(
            LogArea.progress,
            '本集已看完，等待恢复连接后补传',
            level: LogLevel.warning,
          );
        }
      } finally {
        _reporting = false;
        changed();
      }
    });
    return _reports;
  }

  void _retryPendingRecords() {
    if (closed || background || api.session != account) return;
    final now = DateTime.now();
    if (_lastProgressRecovery == api.connection.recovery &&
        _lastPendingRetry != null &&
        now.difference(_lastPendingRetry!) < const Duration(seconds: 30)) {
      return;
    }
    _lastProgressRecovery = api.connection.recovery;
    _lastPendingRetry = now;
    // Retrying older episodes must not delay saving/closing this episode.
    unawaited(
      () async {
        bool allowed() => !closed && !background && api.session == account;
        await store.retryPendingProgress(
          api,
          account,
          exclude: item.id,
          allowed: allowed,
        );
        await store.completions.retry(api, account, allowed: allowed);
      }().catchError((Object e) {
        store.log.add(
          LogArea.progress,
          '历史进度补传未完成：${safeError(e)}',
          level: LogLevel.warning,
        );
      }),
    );
  }

  Future<void> toggle() async {
    if (!ready || closed) return;
    final action = backend.snapshot.playing ? '用户暂停' : '用户继续';
    _recordAction('$action请求');
    try {
      if (backend.snapshot.playing) {
        await backend.pause();
        await endSpeedHold();
      } else {
        await endSpeedHold();
        if (_completed) await seek(Duration.zero);
        await backend.play();
      }
    } catch (e) {
      _recordAction('$action失败：${safeError(e)}', level: LogLevel.warning);
      rethrow;
    }
    _recordAction('$action命令完成');
    unawaited(
      report(
        'Progress',
        eventName: backend.snapshot.playing ? 'Unpause' : 'Pause',
      ),
    );
  }

  Future<void> pauseForBackground({
    PauseSource source = PauseSource.lifecycle,
  }) async {
    final wasBackground = background;
    background = true;
    if (!closed) {
      if (!wasBackground) _recordAction('自动暂停请求；来源=${source.label}');
      await backend.pause();
      await endSpeedHold();
      if (!wasBackground) _recordAction('自动暂停命令完成；来源=${source.label}');
      if (_started) unawaited(report('Progress', eventName: 'Pause'));
    }
  }

  void foreground() {
    final wasBackground = background;
    background = false;
    if (wasBackground && !closed) _recordAction('回到前台；没有自动恢复播放');
  }

  Future<void> seek(
    Duration value, {
    SeekSource source = SeekSource.direct,
  }) async {
    if (!ready || closed) return;
    final max = backend.snapshot.duration.inMilliseconds;
    final target = Duration(
      milliseconds: value.inMilliseconds.clamp(
        0,
        max > 0 ? max : value.inMilliseconds.clamp(0, 1 << 50),
      ),
    );
    final previous = position;
    final previousRestartIntent = _restartDisplayIntent;
    final previousCompleted = _completed;
    final previousEndReported = _endReported;
    final previousCompletionWarning = _completionWarning;
    final commandClock = Stopwatch()..start();
    final command = ++_seekCommands;
    _seekCompletion = null;
    _seeking = true;
    _restartDisplayIntent = target == Duration.zero;
    _completed = false;
    _endReported = false;
    _completionWarning = null;
    _position.beginSeek(target);
    _beginLoading('定位');
    store.log.add(
      LogArea.player,
      '用户定位：原位置=${previous.inMilliseconds} ms；目标=${target.inMilliseconds} ms；'
      '请求目标=${value.inMilliseconds} ms；来源=${source.label}；$_diagnosticId；定位编号=$command；$_diagnosticState',
    );
    try {
      await endSpeedHold();
      if (closed || command != _seekCommands) return;
      await backend.seek(target);
      if (closed || command != _seekCommands) return;
    } catch (e) {
      if (closed || command != _seekCommands) {
        _recordAction('旧定位结果已被更新的定位或退出替代；定位编号=$command；不覆盖当前进度');
        return;
      }
      _seekCompletion = null;
      _position.reset(previous);
      _restartDisplayIntent = previousRestartIntent;
      _completed = previousCompleted;
      _endReported = previousEndReported;
      _completionWarning = previousCompletionWarning;
      _endLoading('定位失败');
      _recordAction(
        '定位命令失败；定位编号=$command；耗时=${commandClock.elapsedMilliseconds} ms；${safeError(e)}',
        level: LogLevel.warning,
      );
      rethrow;
    } finally {
      if (command == _seekCommands) _seeking = false;
    }
    // A real EOF can arrive while the seek Future is still completing. The
    // state listener intentionally ignores old positions during a seek; after
    // this same intent finishes, consume only a real end at the requested end.
    // A command returning without EOF never fabricates completion.
    final candidate = _seekCompletion;
    _seekCompletion = null;
    final settled = candidate?.command == command
        ? candidate!.state
        : backend.snapshot;
    if (ready &&
        error == null &&
        settled.completed &&
        settled.duration > Duration.zero &&
        target >= settled.duration - const Duration(seconds: 3) &&
        settled.position >= settled.duration - const Duration(seconds: 3)) {
      _confirmCompleted(settled);
      if (_completed && _started && !_endReported) {
        unawaited(report('Stopped'));
      }
    }
    _recordAction(
      '定位命令完成；定位编号=$command；目标=${target.inMilliseconds} ms；'
      '耗时=${commandClock.elapsedMilliseconds} ms；画面恢复需核对后续输出与缓冲记录',
    );
    if (!backend.snapshot.buffering) _endLoading('定位命令完成');
    if (!_completed) unawaited(report('Progress'));
    changed();
  }

  bool get canChangeSpeed =>
      ready &&
      !loading &&
      !closed &&
      !background &&
      error == null &&
      !_seeking &&
      !backend.snapshot.buffering;

  Future<void> setSpeed(
    double value, {
    SpeedChangeSource source = SpeedChangeSource.direct,
  }) async {
    // Releasing an already active hold must still restore the original speed,
    // even if the media began buffering or the app lost focus during the hold.
    final restoring = const {
      SpeedChangeSource.holdEnd,
      SpeedChangeSource.holdCancel,
      SpeedChangeSource.holdRestore,
    }.contains(source);
    if (!canChangeSpeed && !restoring) return;
    if (!value.isFinite || value < .5 || value > 3) {
      throw const AppFailure('播放倍速超出支持范围');
    }
    if (source == SpeedChangeSource.menu ||
        source == SpeedChangeSource.direct) {
      // An explicit choice replaces the held gesture's saved base too.
      _holdRestoreSpeed = null;
    }
    await _rateRequests.request(value, source);
    // Selecting the already-active hold rate is an explicit new base too;
    // the rate queue correctly skips a redundant native write in that case.
    if (!closed &&
        speed == value &&
        (source == SpeedChangeSource.menu ||
            source == SpeedChangeSource.direct)) {
      _continuitySpeed = value;
    }
  }

  Future<void> _applySpeed(double value, SpeedChangeSource source) async {
    if (!closed) {
      final before = speed;
      final watch = Stopwatch()..start();
      _recordAction('倍速调整请求；来源=${source.label}；原倍速=$before；目标倍速=$value');
      try {
        await backend.rate(value);
      } catch (e) {
        _speedFailures++;
        _recordAction(
          '倍速调整失败；来源=${source.label}；目标倍速=$value；'
          '耗时=${watch.elapsedMilliseconds} ms；${safeError(e)}',
          level: LogLevel.warning,
        );
        rethrow;
      }
      if (closed) return;
      speed = value;
      if (source == SpeedChangeSource.menu ||
          source == SpeedChangeSource.direct ||
          source == SpeedChangeSource.continuity) {
        _continuitySpeed = value;
      }
      _speedChanges++;
      _recordAction(
        '倍速调整命令完成；来源=${source.label}；原倍速=$before；当前倍速=$value；'
        '耗时=${watch.elapsedMilliseconds} ms',
      );
      if (_started) {
        unawaited(report('Progress', eventName: 'PlaybackRateChange'));
      }
      changed();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _recordAction('退出播放请求');
    closed = true;
    if (backend is PlaybackDiagnosticLifecycle) {
      (backend as PlaybackDiagnosticLifecycle).stopDiagnostics();
    }
    _releaseSubtitlePositionOwners();
    _seekCompletion = null;
    _holdRestoreSpeed = null;
    final ratesClosed = _rateRequests.close();
    _endLoading('退出播放');
    trackSelection?.close();
    _timer?.cancel();
    await _stateSub?.cancel();
    await _errorSub?.cancel();
    try {
      await backend.pause();
    } catch (_) {
      /* The decoder may already have failed. */
    }
    await ratesClosed;
    if (_started) await report('Stopped');
    _sessionClock.stop();
    _recordAction(
      '播放会话汇总；倍速命令完成=$_speedChanges；倍速命令失败=$_speedFailures；'
      '用户定位=$_seekCommands；播放缓冲次数=$_bufferEvents；'
      '已记录播放缓冲合计=$_bufferWaitMs ms；有播放错误=${error != null}；进度同步警告=${syncWarning != null}',
    );
    try {
      await backend.dispose();
    } finally {
      for (final document in _manualSubtitles) {
        try {
          await document.close();
        } catch (_) {
          /* Private cache remains reclaimable. */
        }
      }
      _manualSubtitles.clear();
      unawaited(store.log.flush());
    }
  }

  bool get _nearEnd =>
      _mediaDuration > Duration.zero &&
      position >= _mediaDuration - const Duration(seconds: 3);

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
