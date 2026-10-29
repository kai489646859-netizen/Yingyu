import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/accounts.dart';
import 'package:yingyu/core/browse_cache.dart';
import 'package:yingyu/ui/style.dart';
import 'package:yingyu/ui/surface.dart';
import 'package:yingyu/playback/connection_notice.dart';
import 'package:yingyu/playback/controls.dart';
import 'package:yingyu/playback/menu.dart';
import 'package:yingyu/playback/backend.dart';
import 'package:yingyu/playback/device.dart';
import 'package:yingyu/playback/session.dart';
import 'package:yingyu/playback/media_notice.dart';
import 'package:yingyu/playback/episode_neighbors.dart';
import 'package:yingyu/playback/episode_menu.dart';
import 'package:yingyu/playback/info.dart';
import 'package:yingyu/playback/feedback.dart';
import 'package:yingyu/playback/episode_actions.dart';
import 'package:yingyu/playback/intro_editor.dart';
import 'package:yingyu/playback/episode_continuity.dart';
import 'package:yingyu/playback/orientation.dart';
import 'package:yingyu/playback/player_status.dart';
import 'package:yingyu/playback/opening_metadata.dart';
import 'package:yingyu/playback/subtitle_import.dart';
import 'package:yingyu/core/log.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.createSession,
    this.fromBeginning = false,
    this.createSessionForItem,
    this.browse,
    this.allowNetwork,
  });
  final PlaybackSession Function() createSession;
  final bool fromBeginning;
  final PlaybackSession Function(MediaItem)? createSessionForItem;
  final BrowseRepository? browse;
  final Future<bool> Function(BuildContext)? allowNetwork;
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> with WidgetsBindingObserver {
  late PlaybackSession session;
  final menuAnchors = {
    for (final name in [
      'root',
      'quality',
      'rate',
      'audio',
      'subtitles',
      'episodes',
      'info',
    ])
      name: GlobalKey(),
  };
  Rect? menuAnchor(String pane) {
    final box = (menuAnchors[pane] ?? menuAnchors['root'])?.currentContext
        ?.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox || !box.attached) {
      return null;
    }
    return box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  }

  final orientation = PlaybackOrientation();
  late final Future<void> orientationReady;
  bool controls = true, exiting = false;
  bool audioDucked = false;
  bool locked = false, unlockVisible = false, foreground = true;
  final playerStatus = PlayerStatusController();
  final _touchPointers = <int>{};
  bool get boosted => session.holdingSpeed;
  Timer? hideTimer;
  String? sourceNotice;
  String? _lastOutputNotice;
  bool _automaticOpen = false;
  Object? _canvasOwner;
  String _canvasSize = '';
  void resizeCanvas(BoxConstraints size) {
    if (session.backend is! MpvBackend || session.closed || exiting) return;
    final owner = session;
    final ratio = View.of(context).devicePixelRatio;
    final width = (size.maxWidth * ratio).round();
    final height = (size.maxHeight * ratio).round();
    final shape = '${width}x$height';
    if (identical(_canvasOwner, owner.backend) && _canvasSize == shape) return;
    _canvasOwner = owner.backend;
    _canvasSize = shape;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || exiting || session != owner || owner.closed) return;
      unawaited(
        (owner.backend as MpvBackend)
            .resizeScreenViewport(width, height)
            .catchError((Object failure) {
              if (mounted && session == owner && !exiting) {
                setState(() => operationError = safeError(failure));
              }
            }),
      );
    });
  }

  double brightness = .5, volume = .5;
  Duration? scrub;
  Duration dragStart = Duration.zero;
  double dragDx = 0, dragDy = 0, levelStart = .5;
  bool leftSide = false;
  String? overlay, operationError;
  BoxFit fit = BoxFit.contain;
  MediaItem? selectedEpisode;
  EpisodeNeighbors neighbors = const EpisodeNeighbors();
  bool switching = false;
  bool switchingNext = false;
  bool retrying = false;
  Future<void>? retryJob;
  Future<void>? deviceRelease;
  Future<void> releaseDevice() => deviceRelease ??= Device.release();
  String? neighborWarning, previousSyncWarning;
  EpisodeContinuity? continuity;
  OpeningMetadata? _openingMetadata;
  late final episodeData = EpisodeMenuData(session.api, browse: widget.browse);

  Future<void> showEpisodes() async {
    if (locked || switching || exiting || !session.ready) return;
    final owner = session;
    hideTimer?.cancel();
    final chosen = await showSurface<MediaItem>(
      context,
      playerMenu: true,
      anchor: menuAnchor('episodes'),
      anchorProvider: () => mounted ? menuAnchor('episodes') : null,
      (_) => EpisodeMenu(current: owner.item, data: episodeData),
    );
    if (!mounted || session != owner || owner.closed || exiting) return;
    if (chosen != null && chosen.id != owner.item.id) {
      await switchEpisode(chosen);
    }
    if (mounted) scheduleHide();
  }

  Future<void> loadNeighbors(PlaybackSession owner) async {
    if (widget.createSessionForItem == null) return;
    try {
      final value = await EpisodeNeighbors.load(owner.api, owner.item);
      if (mounted && session == owner && !owner.closed) {
        setState(() {
          neighbors = value;
          neighborWarning = null;
        });
      }
    } catch (e) {
      if (mounted && session == owner && !owner.closed) {
        setState(() => neighborWarning = '相邻分集读取失败：${safeError(e)}；可返回选集重试');
      }
    }
  }

  Future<void> switchEpisode(MediaItem target, {bool automatic = false}) async {
    if (switching ||
        exiting ||
        !session.ready ||
        target.id == session.item.id ||
        widget.createSessionForItem == null) {
      return;
    }
    setState(() {
      switching = true;
      switchingNext = neighbors.next?.id == target.id;
      controls = true;
    });
    if (widget.allowNetwork != null && !await widget.allowNetwork!(context)) {
      if (mounted) {
        setState(() {
          switching = false;
          switchingNext = false;
        });
      }
      return;
    }
    if (!mounted || exiting || session.closed) return;
    if (session.api.session != session.account) {
      setState(() {
        switching = switchingNext = false;
        operationError = '账户已切换，请退出播放器后重新打开影片';
      });
      return;
    }
    hideTimer?.cancel();
    _openingMetadata?.cancel();
    final metadata = OpeningMetadata.begin(session.api, target.id);
    _openingMetadata = metadata;
    try {
      await act(() async {
        await restoreRate();
        final old = session;
        continuity = old.continuitySnapshot;
        old.removeListener(changed);
        await old.close();
        previousSyncWarning = old.syncWarning ?? previousSyncWarning;
        if (!mounted) return;
        selectedEpisode = target;
        fit = BoxFit.contain;
        scrub = null;
        neighbors = const EpisodeNeighbors();
        neighborWarning = null;
        try {
          await start(
            fromBeginning: false,
            metadata: metadata,
            automatic: automatic,
          );
        } catch (e) {
          old.loading = false;
          old.error = safeError(e);
          rethrow;
        } finally {
          if (session != old) old.dispose();
        }
      });
    } finally {
      metadata.cancel();
      if (_openingMetadata == metadata) _openingMetadata = null;
    }
    if (mounted) {
      setState(() {
        switching = false;
        switchingNext = false;
      });
    }
  }

  Future<void> showInfo() async {
    if (locked) return;
    hideTimer?.cancel();
    await showSurface<void>(
      context,
      playerMenu: true,
      (_) => Theme(
        data: playerTheme(context),
        child: PlaybackInfoPage(session: session),
      ),
    );
    if (mounted) scheduleHide();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    playerStatus.addListener(statusChanged);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Device.channel.setMethodCallHandler((call) async {
      if (call.method == 'audioFocus') {
        final kind = call.arguments;
        if (!const {'duck', 'gain', 'transient', 'loss'}.contains(kind) ||
            !mounted ||
            exiting ||
            session.closed) {
          return;
        }
        final owner = session;
        owner.store.log.add(LogArea.player, '音频焦点通知：$kind；仅影响本次播放');
        audioDucked = kind == 'duck';
        if (kind == 'transient' || kind == 'loss') {
          await pause(PauseSource.interruption);
          if (!mounted || exiting || session != owner || owner.closed) return;
          setState(() {
            if (!locked) controls = true;
            overlay = kind == 'transient' ? '音频焦点暂时中断，已暂停' : '音频播放权限已转移，已暂停';
          });
        }
        final backend = owner.backend;
        if (backend is PlaybackDuckingBackend) {
          try {
            await (backend as PlaybackDuckingBackend).setAudioDucked(
              audioDucked,
            );
          } catch (_) {
            if (mounted && !exiting && session == owner && !owner.closed) {
              await pause(PauseSource.interruption);
              owner.store.log.add(
                LogArea.player,
                '音频焦点音量调整失败，已暂停',
                level: LogLevel.warning,
              );
            }
          }
        }
        return;
      }
      if (call.method == 'interruption') {
        await pause(PauseSource.interruption);
        if (mounted) {
          setState(() {
            if (!locked) controls = true;
            overlay = call.arguments?.toString();
          });
        }
      }
    });
    orientationReady = orientation.enter().catchError((Object error) {
      if (mounted) setState(() => operationError = safeError(error));
    });
    start();
  }

  Future<void> start({
    bool? fromBeginning,
    OpeningMetadata? metadata,
    bool automatic = false,
  }) async {
    playerStatus.setActive(false);
    locked = unlockVisible = false;
    sourceNotice = null;
    _automaticOpen = automatic;
    session =
        (selectedEpisode == null
              ? widget.createSession()
              : widget.createSessionForItem!(selectedEpisode!))
          ..addListener(changed);
    final owner = session;
    owner.skipOpeningIntro = automatic;
    if (mounted) {
      setState(() {
        controls = true;
        operationError = null;
      });
    }
    try {
      if (widget.allowNetwork != null && !await widget.allowNetwork!(context)) {
        owner.loading = false;
        owner.error = '已取消流量播放';
        owner.changed();
        return;
      }
      if (!mounted || exiting || owner.closed || session != owner) return;
      // Read only fresh metadata while independent device preparation runs.
      // No source/PlaybackInfo request starts until the original checks finish.
      metadata ??= OpeningMetadata.begin(owner.api, owner.item.id);
      if (_openingMetadata != metadata) _openingMetadata?.cancel();
      _openingMetadata = metadata;
      if (!await Device.focus()) owner.background = true;
      if (!mounted || exiting || owner.closed || session != owner) return;
      final duckBackend = owner.backend;
      if (audioDucked && duckBackend is PlaybackDuckingBackend) {
        await (duckBackend as PlaybackDuckingBackend).setAudioDucked(true);
      }
      final levels = await Device.levels();
      owner.api.log?.add(
        LogArea.player,
        '进入播放器亮度：${Device.brightnessDescription(levels)}',
      );
      brightness = (levels['brightness'] as num).toDouble();
      volume = (levels['volume'] as num).toDouble();
      if (!mounted || exiting || owner.closed || session != owner) return;
      if (owner.backend is MpvBackend) {
        await orientationReady;
        if (!mounted || exiting || owner.closed || session != owner) return;
        if (orientation.phone) {
          final display = View.of(context).display;
          await (owner.backend as MpvBackend).configurePhoneViewport(
            display.size.longestSide.round(),
            display.size.shortestSide.round(),
          );
        } else {
          final viewport = View.of(context).physicalSize;
          await (owner.backend as MpvBackend).configureScreenViewport(
            viewport.width.round(),
            viewport.height.round(),
          );
        }
      }
      if (!mounted || exiting || owner.closed || session != owner) return;
      owner.configureSubtitleViewport(phone: orientation.phone);
      await owner.open(
        metadata: metadata,
        continuity: continuity,
        fromBeginning:
            fromBeginning ?? (selectedEpisode == null && widget.fromBeginning),
      );
      if (!mounted || exiting || owner.closed || session != owner) return;
      if (session.ready) {
        unawaited(loadNeighbors(session));
        unawaited(recordBrightness(owner, '画面就绪'));
      }
      if (mounted && session.ready && !session.closed) {
        final backend = session.backend;
        final notice = backend is MediaNoticeBackend
            ? (backend as MediaNoticeBackend).sourceNotice
            : mediaNotice(
                bluray: false,
                streams: session.route?.streams ?? const [],
              );
        setState(() {
          sourceNotice =
              notice.isEmpty || (_automaticOpen && notice == _lastOutputNotice)
              ? null
              : notice;
          _lastOutputNotice = notice;
        });
      }
      scheduleHide();
    } catch (e) {
      if (mounted && !exiting && session == owner && !owner.closed) {
        hideTimer?.cancel();
        setState(() {
          session.loading = false;
          session.error = safeError(e);
          locked = false;
          unlockVisible = false;
          controls = true;
        });
      }
    } finally {
      metadata?.cancel();
      if (_openingMetadata == metadata) _openingMetadata = null;
    }
  }

  Future<void> recordBrightness(PlaybackSession owner, String stage) async {
    if (owner.api.log?.enabled != true) return;
    try {
      final levels = await Device.levels().timeout(
        const Duration(milliseconds: 600),
      );
      if (mounted && session == owner) {
        owner.api.log?.add(
          LogArea.player,
          '$stage 亮度：${Device.brightnessDescription(levels)}',
        );
      }
    } catch (_) {
      // Optional local diagnostics never block opening or change brightness.
    }
  }

  void changed() {
    if (!mounted) return;
    if (locked && session.error != null) {
      locked = unlockVisible = false;
      controls = true;
      hideTimer?.cancel();
    }
    if (sourceNotice != null && session.backend is MediaNoticeBackend) {
      sourceNotice = (session.backend as MediaNoticeBackend).sourceNotice;
    }
    setState(() {});
    unawaited(
      Device.awake(session.backend.snapshot.playing).catchError((Object e) {
        if (mounted) setState(() => operationError = safeError(e));
      }),
    );
  }

  Future<void> act(Future<void> Function() work) async {
    try {
      await work();
      if (mounted) setState(() => operationError = null);
    } catch (e) {
      if (mounted) {
        setState(() {
          operationError = safeError(e);
          if (locked) {
            locked = unlockVisible = false;
            controls = true;
            hideTimer?.cancel();
          }
        });
      }
    }
  }

  Future<void> pause([PauseSource source = PauseSource.lifecycle]) async {
    playerStatus.setKeepRateWarm(false);
    playerStatus.setActive(false);
    if (mounted) setState(() => overlay = null);
    await session.pauseForBackground(source: source);
  }

  Future<void> toggle() async {
    if (locked) return;
    if (!session.backend.snapshot.playing) {
      if (!await Device.focus()) throw const AppFailure('暂时无法取得音频播放权限');
      session.foreground();
    }
    await session.toggle();
    scheduleHide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (state != AppLifecycleState.resumed) {
      playerStatus.setActive(false);
      unawaited(act(pause));
    } else {
      session.foreground();
      if (mounted) {
        setState(() {
          if (!locked) controls = true;
        });
      }
    }
  }

  void scheduleHide() {
    hideTimer?.cancel();
    if (locked) {
      if (!unlockVisible) return;
      hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && locked) setState(() => unlockVisible = false);
      });
      return;
    }
    hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted &&
          session.ready &&
          session.backend.snapshot.playing &&
          scrub == null) {
        setState(() => controls = false);
      }
    });
  }

  void statusChanged() {
    if (mounted) setState(() {});
  }

  void toggleLock() {
    if (exiting || switching) return;
    hideTimer?.cancel();
    setState(() {
      locked = !locked;
      unlockVisible = locked;
      controls = !locked;
      scrub = null;
      overlay = null;
      dragDx = dragDy = 0;
    });
    if (locked) {
      // IgnorePointer blocks new touches, but a different finger may already
      // own a slider or a skip button. Cancel those recognizers as well.
      for (final pointer in _touchPointers.toList()) {
        GestureBinding.instance.cancelPointer(pointer);
      }
      _touchPointers.clear();
      playerStatus.setActive(false);
      unawaited(act(() => restoreRate(SpeedChangeSource.holdCancel)));
    }
    scheduleHide();
  }

  Future<void> retry({bool? fromBeginning}) {
    if (exiting || switching) return Future.value();
    return retryJob ??= retryOnce(
      fromBeginning: fromBeginning,
    ).whenComplete(() => retryJob = null);
  }

  Future<void> retryOnce({bool? fromBeginning}) async {
    setState(() {
      retrying = true;
      controls = true;
    });
    final old = session;
    old.removeListener(changed);
    try {
      await restoreRate();
      if (!old.closed) continuity = old.continuitySnapshot;
      await old.close();
      if (!mounted || exiting) return;
      old.dispose();
      await start(fromBeginning: fromBeginning);
    } catch (e) {
      if (mounted && !exiting) setState(() => operationError = safeError(e));
    } finally {
      if (mounted) setState(() => retrying = false);
    }
  }

  Future<void> discMenu({int? selectedPlaylist}) async {
    if (locked) return;
    final backend = session.backend;
    if (backend is! DiscNavigationBackend || session.route == null) return;
    final disc = backend as DiscNavigationBackend;
    hideTimer?.cancel();
    final selected =
        selectedPlaylist ??
        (await showSurface<PlayerMenuChoice>(
              context,
              playerMenu: true,
              anchor: menuAnchor('root'),
              anchorProvider: () => mounted ? menuAnchor('root') : null,
              toggleAnchor: true,
              (context) => Theme(
                data: playerTheme(context),
                child: PlayerMenu(
                  session: session,
                  initialPane: 'disc',
                  fit: fit,
                  onToggle: () => act(toggle),
                  onSeek: (target) =>
                      act(() => session.seek(target, source: SeekSource.menu)),
                ),
              ),
            ))?.value
            as int?;
    if (!mounted || selected == null || selected == disc.selectedDiscPlaylist) {
      scheduleHide();
      return;
    }
    await act(() async {
      if (selected < 0) {
        await session.store.saveDiscKind(
          session.account,
          session.item.id,
          session.route!.sourceId,
          selected == -2
              ? DiscKind.iso
              : selected == -3
              ? DiscKind.blurayFolder
              : null,
        );
      } else {
        await session.store.saveDiscPlaylist(
          session.account,
          session.item.id,
          session.route!.sourceId,
          selected,
        );
      }
      await retry(fromBeginning: selected >= 0 ? true : null);
    });
  }

  Future<void> leave() async {
    if (exiting || switching) return;
    playerStatus.setKeepRateWarm(false);
    playerStatus.setActive(false);
    setState(() {
      exiting = true;
      locked = unlockVisible = false;
    });
    final directionStarted = DateTime.now();
    Object? directionFailure;
    final directionRestored = orientation.release().catchError((Object error) {
      directionFailure = error;
    });
    await restoreRate();
    session.removeListener(changed);
    await act(session.close);
    await act(releaseDevice);
    unawaited(recordBrightness(session, '退出恢复后'));
    await act(() async {
      await directionRestored;
      if (directionFailure != null) throw directionFailure!;
    });
    if (orientation.phone) {
      // The browser page must not become visible in the old landscape layout.
      final deadline = DateTime.now().add(const Duration(milliseconds: 900));
      while (mounted &&
          View.of(context).physicalSize.width >
              View.of(context).physicalSize.height &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
    // Tablets restore their original automatic orientation policy. Do not
    // issue a temporary portrait request on a landscape tablet.
    final settle =
        const Duration(milliseconds: 350) -
        DateTime.now().difference(directionStarted);
    if (settle > Duration.zero) await Future<void>.delayed(settle);
    if (mounted) {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 250),
        onTimeout: () {},
      );
    }
    await act(orientation.finishExit);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted) {
      Navigator.of(context).pop(session.syncWarning ?? previousSyncWarning);
    }
  }

  Future<void> restoreRate([
    SpeedChangeSource source = SpeedChangeSource.holdRestore,
  ]) async {
    if (mounted) setState(() => overlay = null);
    await session.endSpeedHold(source: source);
  }

  @override
  void dispose() {
    _openingMetadata?.cancel();
    hideTimer?.cancel();
    playerStatus.removeListener(statusChanged);
    playerStatus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    Device.channel.setMethodCallHandler(null);
    session.removeListener(changed);
    session.dispose();
    unawaited(
      orientation.release().then((_) => orientation.finishExit()).catchError((
        Object error,
      ) {
        session.api.log?.add(LogArea.app, '退出播放时屏幕方向恢复失败：${safeError(error)}');
      }),
    );
    unawaited(
      releaseDevice().catchError((Object error) {
        session.api.log?.add(LogArea.app, '退出播放时设备状态恢复失败：${safeError(error)}');
      }),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> playerMenu([String pane = 'root']) async {
    if (locked) return;
    if (pane == 'rate' && !session.canChangeSpeed) return;
    hideTimer?.cancel();
    if (!mounted) return;
    final chosen = await showSurface<PlayerMenuChoice>(
      context,
      playerMenu: true,
      anchor: menuAnchor(pane),
      anchorProvider: () => mounted ? menuAnchor(pane) : null,
      toggleAnchor: pane == 'root',
      (context) => Theme(
        data: playerTheme(context),
        child: PlayerMenu(
          session: session,
          initialPane: pane,
          fit: fit,
          onToggle: () => act(toggle),
          onSeek: (target) =>
              act(() => session.seek(target, source: SeekSource.menu)),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => controls = true);
    if (chosen != null) {
      switch (chosen.pane) {
        case 'subtitleImport':
          final owner = session;
          await act(() async {
            final document = await SubtitleImport.pick();
            if (document == null) return;
            if (!mounted ||
                exiting ||
                session != owner ||
                owner.closed ||
                owner.api.session != owner.account) {
              await document.close();
              return;
            }
            await owner.attachSubtitle(document);
          });
        case 'subtitles':
        case 'audio':
          await act(
            () => session.chooseTrack(
              chosen.pane == 'subtitles',
              chosen.value as TrackOption,
            ),
          );
        case 'rate':
          await act(
            () => session.setSpeed(
              chosen.value as double,
              source: SpeedChangeSource.menu,
            ),
          );
        case 'fit':
          final nextFit = chosen.value as BoxFit;
          if (session.backend is MpvBackend) {
            var applied = false;
            await act(() async {
              await (session.backend as MpvBackend).setPhoneFill(
                nextFit == BoxFit.cover,
              );
              applied = true;
            });
            if (!applied) return;
          }
          if (mounted) setState(() => fit = nextFit);
        case 'disc':
          await discMenu(selectedPlaylist: chosen.value as int);
        case 'intro':
          final owner = session;
          await showSurface<void>(
            context,
            playerMenu: true,
            anchor: menuAnchor('root'),
            anchorProvider: () => mounted ? menuAnchor('root') : null,
            toggleAnchor: true,
            (_) => Theme(
              data: playerTheme(context),
              child: IntroEditor(session: owner),
            ),
          );
      }
    }
    scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final noticeOwner = session;
    final state = session.backend.snapshot;
    final backend = session.backend;
    final duration = state.duration;
    final position = scrub ?? session.position;
    final speedFeedback = boosted && session.ready && session.error == null;
    final feedback =
        overlay ??
        (speedFeedback
            ? '${session.speed.toStringAsFixed(session.speed == session.speed.roundToDouble() ? 0 : 2).replaceFirst(RegExp(r'0$'), '')}倍速'
            : null);
    final showingSpeed = overlay == null && speedFeedback;
    final chromeVisible =
        !locked &&
        !boosted &&
        (controls || session.loading || session.error != null);
    playerStatus.setKeepRateWarm(
      foreground &&
          !session.background &&
          !exiting &&
          !session.closed &&
          session.error == null,
    );
    playerStatus.setActive(
      foreground &&
          !session.background &&
          !exiting &&
          chromeVisible &&
          (ModalRoute.of(context)?.isCurrent ?? true),
    );
    return PopScope(
      canPop: exiting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) leave();
      },
      child: Theme(
        data: playerTheme(context),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Listener(
            onPointerDown: (event) => _touchPointers.add(event.pointer),
            onPointerUp: (event) => _touchPointers.remove(event.pointer),
            onPointerCancel: (event) => _touchPointers.remove(event.pointer),
            child: LayoutBuilder(
              builder: (context, size) {
                resizeCanvas(size);
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    session.closed || exiting
                        ? const ColoredBox(color: Colors.black)
                        : KeyedSubtree(
                            // The pinned Video widget binds dimension streams in
                            // initState. A replacement backend needs a new view.
                            key: ObjectKey(session.backend),
                            child: session.backend.view(fit),
                          ),
                    if (!session.ready ||
                        session.loading ||
                        exiting ||
                        switching ||
                        retrying)
                      const ColoredBox(
                        key: Key('player-opening-cover'),
                        color: Colors.black,
                      ),
                    GestureDetector(
                      key: const Key('player-touch-surface'),
                      behavior: locked
                          ? HitTestBehavior.opaque
                          : HitTestBehavior.translucent,
                      onTap: () {
                        setState(() {
                          if (locked) {
                            unlockVisible = !unlockVisible;
                          } else {
                            controls = !controls;
                          }
                          overlay = null;
                        });
                        scheduleHide();
                      },
                      onDoubleTap: locked ? null : () => act(toggle),
                      onLongPressStart: (details) {
                        if (!locked &&
                            session.canChangeSpeed &&
                            !exiting &&
                            !switching) {
                          final holdSpeed = session.store.holdSpeed.toDouble();
                          setState(() => overlay = null);
                          act(() => session.beginSpeedHold(holdSpeed));
                        }
                      },
                      onLongPressEnd: (_) {
                        if (boosted) {
                          act(() => restoreRate(SpeedChangeSource.holdEnd));
                        }
                      },
                      onLongPressCancel: () {
                        if (boosted) {
                          act(() => restoreRate(SpeedChangeSource.holdCancel));
                        }
                      },
                      onHorizontalDragStart: (_) {
                        if (locked || !session.ready) return;
                        hideTimer?.cancel();
                        dragStart = session.position;
                        dragDx = 0;
                      },
                      onHorizontalDragUpdate: (details) {
                        if (locked ||
                            !session.ready ||
                            duration == Duration.zero) {
                          return;
                        }
                        dragDx += details.delta.dx;
                        final delta = (dragDx / size.maxWidth * 120000).round();
                        setState(() {
                          scrub = Duration(
                            milliseconds: (dragStart.inMilliseconds + delta)
                                .clamp(0, duration.inMilliseconds),
                          );
                          overlay = clockText(scrub!);
                        });
                      },
                      onHorizontalDragEnd: (_) {
                        if (locked) return;
                        if (scrub != null) {
                          final target = scrub!;
                          setState(() {
                            scrub = null;
                            overlay = null;
                          });
                          act(
                            () => session.seek(
                              target,
                              source: SeekSource.gesture,
                            ),
                          );
                        }
                        scheduleHide();
                      },
                      onHorizontalDragCancel: () => setState(() {
                        scrub = null;
                        overlay = null;
                      }),
                      onVerticalDragStart: (details) {
                        if (locked) return;
                        leftSide = details.localPosition.dx < size.maxWidth / 2;
                        dragDy = 0;
                        levelStart = leftSide ? brightness : volume;
                      },
                      onVerticalDragUpdate: (details) {
                        if (locked) return;
                        dragDy += details.delta.dy;
                        final value =
                            (levelStart - dragDy / size.maxHeight * 1.5).clamp(
                              .0,
                              1.0,
                            );
                        setState(() {
                          if (leftSide) {
                            brightness = value;
                          } else {
                            volume = value;
                          }
                          overlay =
                              '${leftSide ? '亮度' : '音量'} ${(value * 100).round()}%';
                        });
                        act(
                          () => leftSide
                              ? Device.brightness(value)
                              : Device.volume(value),
                        );
                      },
                      onVerticalDragEnd: (_) {
                        if (locked) return;
                        setState(() => overlay = null);
                        if (leftSide) {
                          unawaited(recordBrightness(session, '亮度手势结束'));
                        }
                      },
                      onVerticalDragCancel: () =>
                          setState(() => overlay = null),
                    ),
                    PlayerChrome(
                      status: playerStatus.value,
                      locked: locked,
                      unlockVisible: unlockVisible,
                      onLock: locked || (!exiting && session.error == null)
                          ? toggleLock
                          : null,
                      menuAnchors: menuAnchors,
                      title: session.item.title,
                      accountLabel:
                          '${accountName(session.account)} · ${accountServer(session.account)}',
                      visible: chromeVisible,
                      ready: session.ready && session.error == null,
                      playing: state.playing,
                      position: position,
                      duration: duration,
                      onBack: exiting || switching ? null : leave,
                      onPrevious: switching || neighbors.previous == null
                          ? null
                          : () {
                              if (!locked) switchEpisode(neighbors.previous!);
                            },
                      onNext: switching || neighbors.next == null
                          ? null
                          : () {
                              if (!locked) switchEpisode(neighbors.next!);
                            },
                      onInfo: showInfo,
                      onQuality: () => playerMenu('quality'),
                      onAudio: () => playerMenu('audio'),
                      onSubtitles: () => playerMenu('subtitles'),
                      onEpisodes:
                          widget.createSessionForItem != null &&
                              session.item.type == 'Episode' &&
                              !switching
                          ? showEpisodes
                          : null,
                      onRate: session.canChangeSpeed
                          ? () => playerMenu('rate')
                          : null,
                      speed: session.speed,
                      onToggle: () => act(toggle),
                      onSeekBack: () {
                        if (locked) return;
                        act(
                          () => session.seek(
                            session.position - const Duration(seconds: 10),
                            source: SeekSource.skip,
                          ),
                        );
                      },
                      onSeekForward: () {
                        if (locked) return;
                        act(
                          () => session.seek(
                            session.position + const Duration(seconds: 10),
                            source: SeekSource.skip,
                          ),
                        );
                      },
                      onMenu: playerMenu,
                      onScrubStart: () {
                        if (!locked) hideTimer?.cancel();
                      },
                      onScrub: (value) {
                        if (!locked) {
                          setState(
                            () => scrub = Duration(milliseconds: value.round()),
                          );
                        }
                      },
                      onScrubEnd: (value) {
                        if (locked) return;
                        setState(() => scrub = null);
                        act(
                          () => session.seek(
                            Duration(milliseconds: value.round()),
                            source: SeekSource.slider,
                          ),
                        );
                        scheduleHide();
                      },
                      warning:
                          operationError ??
                          session.trackSelection?.warning ??
                          neighborWarning,
                    ),
                    if (session.loading || exiting || switching || retrying)
                      AbsorbPointer(
                        absorbing: switching,
                        child: MessagePanel(
                          exiting
                              ? '正在保存进度'
                              : switching
                              ? '正在切换分集'
                              : retrying
                              ? '正在重新连接'
                              : state.openingStage,
                          busy: true,
                        ),
                      ),
                    if (session.error != null && !retrying)
                      Center(
                        child: Container(
                          color: Colors.black87,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              MessagePanel(
                                session.error!,
                                retry: exiting ? null : retry,
                              ),
                              if (!exiting &&
                                  session.route != null &&
                                  session.backend is DiscNavigationBackend)
                                TextButton(
                                  onPressed: discMenu,
                                  child: const Text('原盘读取方式'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (state.buffering && session.ready)
                      Center(
                        child: IgnorePointer(
                          child: CupertinoActivityIndicator(
                            color: accentColor(context),
                          ),
                        ),
                      ),
                    if (feedback != null)
                      IgnorePointer(
                        child: PlaybackFeedback(
                          text: feedback,
                          boosted: showingSpeed,
                          fit: fit,
                          aspectRatio: backend is VideoGeometryBackend
                              ? (backend as VideoGeometryBackend)
                                    .videoAspectRatio
                              : null,
                        ),
                      ),
                    if (sourceNotice?.isNotEmpty == true)
                      Positioned(
                        key: ObjectKey(session),
                        top: showingSpeed
                            ? math.max(
                                76,
                                MediaQuery.sizeOf(context).height * .10 + 28,
                              )
                            : 76,
                        left: 20,
                        right: 20,
                        child: IgnorePointer(
                          child: SafeArea(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: SourceFormatNotice(
                                key: const ValueKey(
                                  'source-format-presentation',
                                ),
                                text: sourceNotice!,
                                suspended: state.buffering,
                                visible:
                                    session.ready &&
                                    !locked &&
                                    !session.completed &&
                                    session.error == null &&
                                    !exiting &&
                                    !switching &&
                                    !retrying &&
                                    (ModalRoute.of(context)?.isCurrent ?? true),
                                onDone: () {
                                  if (mounted && session == noticeOwner) {
                                    setState(() => sourceNotice = null);
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    IgnorePointer(
                      ignoring: locked,
                      child: Opacity(
                        opacity: locked ? 0 : 1,
                        child: EpisodeActions(
                          key: ValueKey(('episode-actions', session)),
                          session: session,
                          next: neighbors.next,
                          enabled:
                              !exiting &&
                              !switching &&
                              !retrying &&
                              scrub == null &&
                              (ModalRoute.of(context)?.isCurrent ?? true),
                          controls: controls,
                          onNext: (item) =>
                              switchEpisode(item, automatic: true),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 110,
                      left: 8,
                      right: 8,
                      child: IgnorePointer(
                        child: PlaybackConnectionNotice(
                          connection: session.api.connection,
                          warning: session.syncWarning ?? previousSyncWarning,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
