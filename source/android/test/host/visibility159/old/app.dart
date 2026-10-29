import 'playback/subtitle_size.dart';
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'core/emby.dart';
import 'core/account_controller.dart';
import 'core/accounts.dart';
import 'ui/accounts.dart';
import 'ui/account_avatar_scope.dart';
import 'core/home_feed.dart';
import 'core/interface_preferences.dart';
import 'ui/poster.dart';
import 'ui/poster_service.dart';
import 'ui/connection_banner.dart';
import 'ui/home.dart';
import 'core/models.dart';
import 'core/store.dart';
import 'playback/backend.dart';
import 'playback/network_permission.dart';
import 'playback/page.dart';
import 'playback/session.dart';
import 'ui/detail.dart';
import 'ui/library.dart';
import 'ui/login.dart';
import 'core/browse_cache.dart';
import 'ui/settings.dart';
import 'ui/style.dart';
import 'ui/scroll_behavior.dart';
import 'ui/surface.dart';
import 'version.dart';
import 'ui/release_notes.dart';
import 'ui/swipe_pages.dart';
import 'core/personal_library.dart';
import 'core/version_groups.dart';
import 'ui/version_group.dart';
import 'core/personal_sync.dart';
import 'ui/poster_actions.dart';
import 'ui/personal_status_page.dart';
import 'ui/home_visibility.dart';
import 'core/library_events.dart';

class YingyuApp extends StatelessWidget {
  const YingyuApp({
    super.key,
    required this.store,
    required this.api,
    this.bufferMiB = 64,
    this.backendFactory,
  });
  final AppStore store;
  final EmbyClient api;
  final int bufferMiB;
  final PlayerBackend Function()? backendFactory;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (_, _) => MaterialApp(
      title: '映屿',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      theme: appTheme(
        Brightness.light,
        accentChoice: store.accent,
        visualStyle: store.visualStyle,
      ),
      darkTheme: appTheme(
        Brightness.dark,
        accentChoice: store.accent,
        visualStyle: store.visualStyle,
      ),
      themeMode: store.theme,
      themeAnimationDuration: const Duration(milliseconds: 320),
      themeAnimationCurve: Curves.easeInOutCubic,
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      builder: (context, child) => AppVisualBackdrop(
        child: AccountAvatarScope(
          avatars: store.avatars,
          transport: api,
          child: SubtitleSizeScope(
            scale: store.subtitleScale,
            child: HomeVisibilityScope(order: store.homeOrder, child: child!),
          ),
        ),
      ),
      home: SessionGate(
        store: store,
        api: api,
        createBackend:
            backendFactory ??
            () => MpvBackend(
              nativeHdr: store.nativeHdr,
              bufferBytes: bufferMiB * 1024 * 1024,
              log: store.log,
            ),
      ),
    ),
  );
}

class SessionGate extends StatefulWidget {
  const SessionGate({
    super.key,
    required this.store,
    required this.api,
    required this.createBackend,
  });
  final AppStore store;
  final EmbyClient api;
  final PlayerBackend Function() createBackend;
  @override
  State<SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<SessionGate> {
  late final accounts = AccountController(widget.store, widget.api);
  bool restoring = true;
  EmbyClient? displayedApi;
  @override
  void initState() {
    super.initState();
    accounts.addListener(changed);
    accounts.onExpired = () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      });
    };
    unawaited(restore());
  }

  void changed() {
    if (!mounted) return;
    if (displayedApi != accounts.api) {
      displayedApi = accounts.api;
      PosterDemand.pause(accounts, true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        PosterDemand.pause(accounts, false);
      });
    }
    setState(() {});
  }

  Future<void> restore() async {
    setState(() => restoring = true);
    try {
      await accounts.restore();
    } finally {
      if (mounted) setState(() => restoring = false);
    }
  }

  @override
  void dispose() {
    PosterDemand.pause(accounts, false);
    accounts.removeListener(changed);
    accounts.dispose();
    super.dispose();
  }

  Future<void> logout() async {
    final account = accounts.selected;
    if (account != null) {
      await accounts.remove(account, switchToRemaining: true);
      if (mounted && accounts.connected && accounts.error != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(accounts.error!)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (restoring) {
      return const Scaffold(body: MessagePanel('正在恢复 Emby 登录', busy: true));
    }
    if (accounts.connected) {
      return HomePage(
        key: ObjectKey(accounts.api),
        api: accounts.api!,
        store: widget.store,
        createBackend: widget.createBackend,
        logout: logout,
        openAccounts: () =>
            showAccountPicker(context, accounts, allowReorder: true),
      );
    }
    if (accounts.switchingAfterLogout) {
      return const Scaffold(body: MessagePanel('正在处理账号', busy: true));
    }
    if (accounts.accounts.isNotEmpty || accounts.error != null) {
      return Scaffold(
        body: SafeArea(
          child: PageList(
            children: [
              const SectionHeading('账户'),
              if (accounts.selected != null)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    '上次使用：${accounts.selected!.session.username}\n${accounts.selected!.session.base}',
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  accounts.error ?? '选择一个已保存的账号，或添加新账号。',
                  style: TextStyle(
                    color: accounts.error == null
                        ? secondaryColor(context)
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              SettingsGroup(
                children: [
                  SettingsRow(
                    '选择或管理账号',
                    icon: CupertinoIcons.person_2,
                    onTap: accounts.busy
                        ? null
                        : () => showAccountPicker(context, accounts),
                  ),
                  SettingsRow(
                    '添加账号',
                    icon: CupertinoIcons.person_badge_plus,
                    onTap: accounts.busy
                        ? null
                        : () => showAccountLogin(context, accounts),
                  ),
                  if (accounts.selected != null &&
                      !accounts.selected!.needsLogin)
                    SettingsRow(
                      '重试连接',
                      icon: CupertinoIcons.arrow_clockwise,
                      onTap: accounts.busy ? null : restore,
                    ),
                  if (accounts.selected?.needsLogin == true)
                    SettingsRow(
                      '重新登录',
                      icon: CupertinoIcons.lock,
                      onTap: accounts.busy
                          ? null
                          : () => showAccountLogin(
                              context,
                              accounts,
                              account: accounts.selected,
                            ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return LoginPage(
      login: (s, u, p) => accounts.login(s, u, p),
      loginNamed: (s, u, p, name) => accounts.login(s, u, p, alias: name),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.store,
    required this.createBackend,
    required this.logout,
    this.openAccounts,
  });
  final EmbyClient api;
  final AppStore store;
  final PlayerBackend Function() createBackend;
  final Future<void> Function() logout;
  final Future<void> Function()? openAccounts;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int index = 0;
  MediaItem? requestedLibrary;
  int libraryRequest = 0;
  Timer? exitTimer;
  bool exitHint = false, exitingApp = false;
  final accountPageStorage = PageStorageBucket();
  final pagePosition = ValueNotifier<double>(0);

  void selectTab(int next) {
    if (next == index) return;
    setState(() {
      clearExitHint();
      index = next;
    });
  }

  void clearExitHint() {
    exitTimer?.cancel();
    exitTimer = null;
    exitHint = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!(ModalRoute.of(context)?.isCurrent ?? true) ||
        MediaQuery.viewInsetsOf(context).bottom > 0) {
      clearExitHint();
    }
  }

  Future<void> backFromMain(bool didPop, Object? result) async {
    final route = ModalRoute.of(context);
    if (didPop || !(route?.isCurrent ?? false) || exitingApp) return;
    // Menus and the keyboard consume Back before the root exit gesture.
    if (route!.willHandlePopInternally) {
      setState(clearExitHint);
      Navigator.of(context).pop();
      return;
    }
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      setState(clearExitHint);
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (playing || !foreground) return;
    if (exitTimer?.isActive ?? false) {
      setState(clearExitHint);
      exitingApp = true;
      try {
        await SystemNavigator.pop();
      } catch (e) {
        exitingApp = false;
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(safeError(e))));
        }
      }
      return;
    }
    setState(() => exitHint = true);
    exitTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(clearExitHint);
    });
  }

  bool playing = false;
  void setPlaying(bool value) {
    if (playing == value) return;
    if (!mounted) {
      playing = value;
      return;
    }
    setState(() => playing = value);
  }

  bool foreground = true;
  late final completionAccount = widget.api.session!;
  Future<void>? completionJob;
  Future<void> retryCompletions() => completionJob ??= runCompletionRetry()
      .whenComplete(() => completionJob = null);
  Future<void> runCompletionRetry() async {
    if (personalSync.busy) return;
    await widget.store.retryPendingProgress(
      widget.api,
      completionAccount,
      allowed: () => mounted && !playing && foreground && !personalSync.busy,
    );
    await widget.store.completions.retry(
      widget.api,
      completionAccount,
      allowed: () => mounted && !playing && foreground && !personalSync.busy,
    );
  }

  Timer? connectionTimer;
  void scheduleConnectionCheck() {
    connectionTimer?.cancel();
    if (!mounted || playing || !foreground) return;
    connectionTimer = Timer(const Duration(seconds: 30), () async {
      final last = widget.api.connection.checkedAt;
      if (!libraryEvents.connected &&
          (last == null ||
              DateTime.now().difference(last) >= const Duration(seconds: 30))) {
        try {
          await widget.api.testConnection();
        } catch (_) {
          /* Visible connection state retains the reason. */
        }
      }
      if (mounted && !playing && foreground) await retryCompletions();
      scheduleConnectionCheck();
    });
  }

  late final interfacePreferences = InterfacePreferences(widget.store.prefs);
  late final preferences = BrowsePreferences(widget.store.prefs);
  late final browse = BrowseRepository(
    widget.api,
    widget.store.browseCache,
    preferences,
    visibility: widget.store.homeOrder,
  );
  late final homeFeed = HomeFeed(
    widget.api,
    widget.store,
    browse: browse,
    preloadSearch: true,
  );
  late final libraryEvents = LibraryEvents(
    widget.api,
    onChanges: (removed, added) async {
      if (!mounted || !identical(completionAccount, widget.api.session)) return;
      await browse.acceptLibraryChanges(removed, added);
      if (!mounted || !identical(completionAccount, widget.api.session)) return;
      await homeFeed.acceptRemovals(removed);
      final warning =
          widget.store.homeOrder.removals.warning ?? browse.cache.warning;
      if (warning != null) throw AppFailure(warning);
    },
  );
  late final personalSync = PersonalSync(
    widget.api,
    widget.store.personal,
    store: widget.store,
    waitForPlaybackSync: () async {
      await completionJob;
    },
    onChanged: (saved) => browse.invalidateProgress(saved.id),
    onWatched: homeFeed.acceptWatchedState,
  );
  Widget posterActions(Widget child) => PosterActionsScope(
    sync: personalSync,
    preferences: interfacePreferences,
    feed: homeFeed,
    onItem: item,
    child: child,
  );

  Future<void> searchFromHome() => Navigator.push(
    context,
    CupertinoPageRoute<void>(
      builder: (_) => posterActions(
        Scaffold(
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            child: LibraryPage(
              api: widget.api,
              browse: browse,
              onRefreshAll: homeFeed.refreshAll,
              refreshFeed: homeFeed,
              searchMode: true,
              onItem: item,
              display: phoneLayout(context)
                  ? LibraryDisplay.posters
                  : interfacePreferences.libraryDisplay,
              reducedMotion: interfacePreferences.reducedMotion,
            ),
          ),
        ),
      ),
    ),
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    imageCacheBudget.limitBytes = interfacePreferences.cacheGB * imageGB;
    actorCacheBudget.limitBytes = interfacePreferences.actorCacheGB * imageGB;
    landscapeCacheBudget.limitBytes =
        interfacePreferences.landscapeCacheGB * imageGB;
    imageCacheBudget.references = widget.store.images;
    landscapeCacheBudget.references = widget.store.images;
    widget.store.images.deleteFiles = (hashes, allowed) async {
      await imageCacheBudget.removeUnreferenced(hashes, allowed);
      await landscapeCacheBudget.removeUnreferenced(hashes, allowed);
    };
    browse.onRemoved = homeFeed.acceptRemovals;
    browse.extraItems = () => [
      ...homeFeed.cachedItems,
      for (final list in SavedList.values)
        ...widget.store.personal.items(browse.account, list),
    ];
    imageCacheBudget.autoCleanDays = interfacePreferences.imageAutoCleanDays;
    applyImagePreferences();
    interfacePreferences.addListener(applyImagePreferences);
    scheduleConnectionCheck();
    libraryEvents.setActive(widget.api.liveEvents);
    unawaited(retryCompletions());
  }

  void applyImagePreferences() {
    setImageLoadSpeed(interfacePreferences.imageLoadSpeed);
    setImageRequestLimit(interfacePreferences.imageRequestLimit);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      if (exitHint) clearExitHint();
      exitingApp = false;
      foreground = state == AppLifecycleState.resumed;
    });
    libraryEvents.setActive(foreground && widget.api.liveEvents);
    PosterDemand.pause(this, playing || !foreground);
    scheduleConnectionCheck();
    if (state == AppLifecycleState.resumed && !playing) {
      browse.activate();
      homeFeed.activate();
      unawaited(retryCompletions());
    } else {
      browse.suspend();
      homeFeed.suspend();
      if (state == AppLifecycleState.paused) {
        PaintingBinding.instance.imageCache.clear();
      }
    }
  }

  @override
  void didHaveMemoryPressure() => PaintingBinding.instance.imageCache.clear();

  @override
  void dispose() {
    exitTimer?.cancel();
    connectionTimer?.cancel();
    libraryEvents.dispose();
    pagePosition.dispose();
    PosterDemand.pause(this, false);
    WidgetsBinding.instance.removeObserver(this);
    browse.dispose();
    preferences.dispose();
    interfacePreferences.removeListener(applyImagePreferences);
    interfacePreferences.dispose();
    homeFeed.dispose();
    personalSync.dispose();
    super.dispose();
  }

  bool loggingOut = false;
  Future<void> resumeDetail(MediaItem entry) => item(entry);

  Future<void> item(MediaItem entry) async {
    final permitted = widget.store.homeOrder.visible(widget.api.session!, [
      entry,
    ]);
    if (permitted.isEmpty) return;
    entry = permitted.single;
    if (entry is VersionGroup) {
      final group = entry;
      if (group.owner != accountKey(widget.api.session!)) return;
      final chosen = await showSurface<MediaItem>(
        context,
        (_) => VersionChooser(group: group, api: widget.api, browse: browse),
      );
      if (!mounted ||
          chosen == null ||
          entry.owner != accountKey(widget.api.session!)) {
        return;
      }
      await item(chosen);
      return;
    }
    if (homeFeed.sections.any((s) => s.library.id == entry.id)) {
      setState(() {
        clearExitHint();
        index = 1;
        requestedLibrary = entry;
        libraryRequest++;
      });
      return;
    }
    if (entry.folder && !entry.series && entry.type != 'Season') {
      await Navigator.push(
        context,
        CupertinoPageRoute<void>(
          builder: (_) => posterActions(
            Scaffold(
              resizeToAvoidBottomInset: false,
              appBar: AppBar(
                title: Text(
                  '${accountName(widget.api.session!)} · ${accountServer(widget.api.session!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
                leading: CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: () => Navigator.pop(context),
                  child: const Icon(CupertinoIcons.back),
                ),
              ),
              body: LibraryPage(
                display: phoneLayout(context)
                    ? LibraryDisplay.posters
                    : interfacePreferences.libraryDisplay,
                api: widget.api,
                browse: browse,
                onRefreshAll: homeFeed.refreshAll,
                refreshFeed: homeFeed,
                onItem: item,
                parent: entry,
                reducedMotion: interfacePreferences.reducedMotion,
              ),
            ),
          ),
        ),
      );
    } else {
      final seriesId = entry.data['SeriesId']?.toString() ?? '';
      final seriesChild =
          (entry.type == 'Episode' || entry.type == 'Season') &&
          seriesId.isNotEmpty;
      final detailEntry = seriesChild
          ? MediaItem({
              'Id': seriesId,
              'Type': 'Series',
              'Name': entry.data['SeriesName'] ?? entry.title,
              'ImageTags': {
                'Primary': entry.data['SeriesPrimaryImageTag'] ?? '',
              },
            })
          : entry;
      await showSurface<void>(
        context,
        (_) => posterActions(
          DetailPage(
            store: widget.store,
            personal: widget.store.personal,
            personalSync: personalSync,
            item: detailEntry,
            resumeEpisode:
                homeFeed.recentEpisode(detailEntry.id) ??
                (entry.type == 'Episode' &&
                        (entry.resume > Duration.zero ||
                            object(entry.data['UserData'])['Played'] == true ||
                            DateTime.tryParse(
                                  '${object(entry.data['UserData'])['LastPlayedDate']}',
                                ) !=
                                null)
                    ? entry
                    : null),
            watchedEpisode: homeFeed.lastWatchedEpisode,
            api: widget.api,
            browse: browse,
            play: play,
          ),
        ),
      );
    }
  }

  Future<void> play(MediaItem entry, String? source, bool beginning) async {
    if (!widget.store.homeOrder.allows(widget.api.session!, entry)) return;
    if (playing) return;
    if (personalSync.busy) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在同步个人状态，请稍后播放')));
      return;
    }
    if (homeFeed.removing(entry)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('正在移出继续观看，请稍后播放')));
      return;
    }
    setPlaying(true);
    final networkPermission = PlaybackNetworkPermission(
      allowed: () => widget.store.allowMobilePlayback,
    );
    // No media preparation or player fetch can run before this decision.
    final permitted = await networkPermission.authorize(context);
    if (!mounted || !permitted) {
      setPlaying(false);
      return;
    }
    connectionTimer?.cancel();
    PosterDemand.pause(this, true);
    homeFeed.suspend();
    browse.suspend();
    MediaItem? lastPlayed;
    bool? lastCompleted;
    PlaybackSession makeSession(MediaItem target) {
      final session = PlaybackSession(
        api: widget.api,
        store: widget.store,
        item: target,
        sourceId: target.id == entry.id ? source : null,
        backend: widget.createBackend(),
      );
      void observe() {
        if (session.ready) {
          lastPlayed = target;
          lastCompleted = session.completed;
          personalSync.observed.remove(target.id);
        }
      }

      session.addListener(observe);
      return session;
    }

    String? warning;
    try {
      warning = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerPage(
            allowNetwork: networkPermission.authorize,
            fromBeginning: beginning,
            createSession: () => makeSession(entry),
            createSessionForItem: makeSession,
            browse: browse,
          ),
        ),
      );
    } finally {
      setPlaying(false);
      if (mounted && foreground) {
        browse.activate();
        homeFeed.activate();
      }
      PosterDemand.pause(this, !foreground && mounted);
      scheduleConnectionCheck();
    }
    if (mounted && lastPlayed != null) {
      // Publish the episode actually reached (including automatic next) before
      // the underlying detail page refreshes its highlight.
      await homeFeed.afterPlayback(lastPlayed!, actualCompleted: lastCompleted);
    }
    if (mounted && warning != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(warning), duration: const Duration(seconds: 8)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: interfacePreferences,
    builder: (context, _) => PopScope(
      canPop: false,
      onPopInvokedWithResult: backFromMain,
      child: PageStorage(
        bucket: accountPageStorage,
        child: posterActions(buildHome(context)),
      ),
    ),
  );

  bool retryingConnection = false;
  Future<void> retryConnection() async {
    if (retryingConnection || playing || !foreground) return;
    connectionTimer?.cancel();
    setState(() => retryingConnection = true);
    try {
      await widget.api.testConnection();
      if (!mounted || playing || !foreground) return;
      if (index == 0) await homeFeed.retry();
    } catch (_) {
      // The banner retains the actual connection failure; do not dismiss it.
    } finally {
      if (mounted) {
        setState(() => retryingConnection = false);
        scheduleConnectionCheck();
      }
    }
  }

  Widget buildHome(BuildContext context) {
    final landscape = wideLayout(context);
    final phone = phoneLayout(context);
    final glass = liquidGlassOf(context);
    final dockSpace = phone
        ? (glass ? 80 : 70) + MediaQuery.viewPaddingOf(context).bottom
        : landscape
        ? (glass ? 90 : 80) + MediaQuery.viewPaddingOf(context).bottom
        : 0.0;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final session = widget.api.session!;
    final display = widget.store.accountDisplays.read(session);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(
              // Clear glass needs the actual page behind it. Scroll footers
              // and edge controls still reserve the dock's interaction space.
              bottom: glass ? 0 : dockSpace,
              child: KeyboardCoveredArea(
                bottomSpace: glass ? 0 : dockSpace,
                child: Column(
                  key: const Key('main-browse-content'),
                  children: [
                    Expanded(
                      child: PageHeaderAction(
                        notice: ConnectionBanner(
                          api: widget.api,
                          retry: retryConnection,
                          busy: retryingConnection,
                        ),
                        action: widget.openAccounts == null
                            ? null
                            : AccountSwitchButton(
                                account: session,
                                display: display,
                                onTap: playing ? null : widget.openAccounts,
                              ),
                        child: DockInset(
                          bottom: glass ? dockSpace + 12 : 0,
                          child: SwipePages(
                            index: index,
                            onChanged: selectTab,
                            onProgress: (value) => pagePosition.value = value,
                            reducedMotion: interfacePreferences.reducedMotion,
                            enabled: !playing && foreground,
                            children: [
                              TickerMode(
                                enabled: index == 0,
                                child: HomeDashboard(
                                  feed: homeFeed,
                                  active: index == 0,
                                  connectionRetrying: retryingConnection,
                                  reducedMotion:
                                      interfacePreferences.reducedMotion,
                                  onItem: item,
                                  onSearch: searchFromHome,
                                  onPlay: (entry) => play(entry, null, false),
                                  onResumeDetail: resumeDetail,
                                  onResumeAll: () => Navigator.push(
                                    context,
                                    CupertinoPageRoute<void>(
                                      builder: (context) => posterActions(
                                        Scaffold(
                                          resizeToAvoidBottomInset: false,
                                          appBar: AppBar(
                                            title: Text(
                                              '${accountName(widget.api.session!)} · ${accountServer(widget.api.session!)}',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 13,
                                              ),
                                            ),
                                            leading: CupertinoButton(
                                              padding: EdgeInsets.zero,
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Icon(
                                                CupertinoIcons.back,
                                              ),
                                            ),
                                          ),
                                          body: LibraryPage(
                                            display: phoneLayout(context)
                                                ? LibraryDisplay.posters
                                                : interfacePreferences
                                                      .libraryDisplay,
                                            api: widget.api,
                                            browse: browse,
                                            onRefreshAll: homeFeed.refreshAll,
                                            refreshFeed: homeFeed,
                                            resumeFeed: homeFeed,
                                            reducedMotion: interfacePreferences
                                                .reducedMotion,
                                            onItem: resumeDetail,
                                            onPlay: (entry) =>
                                                play(entry, null, false),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              TickerMode(
                                enabled: index == 1,
                                child: LibraryPage(
                                  display: phoneLayout(context)
                                      ? LibraryDisplay.posters
                                      : interfacePreferences.libraryDisplay,
                                  api: widget.api,
                                  browse: browse,
                                  onRefreshAll: homeFeed.refreshAll,
                                  refreshFeed: homeFeed,
                                  onItem: item,
                                  active: index == 1,
                                  requestedLibrary: requestedLibrary,
                                  libraryRequest: libraryRequest,
                                  reducedMotion:
                                      interfacePreferences.reducedMotion,
                                ),
                              ),
                              SettingsPage(
                                homeFeed: homeFeed,
                                store: widget.store,
                                browse: browse,
                                interfacePreferences: interfacePreferences,
                              ),
                              account(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom:
                  (glass ? 10 : 6) + MediaQuery.viewPaddingOf(context).bottom,
              child: IgnorePointer(
                ignoring: keyboard > 0,
                child: ExcludeSemantics(
                  excluding: keyboard > 0,
                  child: GlassNavigation(
                    progress: pagePosition,
                    reducedMotion: interfacePreferences.reducedMotion,
                    index: index,
                    onChanged: selectTab,
                    onSearch: phone ? null : searchFromHome,
                  ),
                ),
              ),
            ),
            if (exitHint && (ModalRoute.of(context)?.isCurrent ?? true))
              Positioned(
                left: 24,
                right: 24,
                bottom:
                    phoneValue(context, 82, 94) +
                    MediaQuery.viewPaddingOf(context).bottom,
                child: IgnorePointer(
                  child: Center(
                    child: Semantics(
                      liveRegion: true,
                      child: Material(
                        key: const Key('exit-app-hint'),
                        color: Theme.of(context).colorScheme.inverseSurface,
                        borderRadius: BorderRadius.circular(24),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          child: Text(
                            '再按一次退出 app',
                            style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(
                                context,
                              ).colorScheme.onInverseSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> confirmLogout() async {
    if (loggingOut || playing) return;
    final session = widget.api.session!;
    final yes = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('退出当前账号？'),
        content: Text(
          '${accountName(session)}\n${session.base}\n\n仅退出这个账号，其他账号、观看记录和图片缓存保留。再次使用此账号需要登录。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => loggingOut = true);
    try {
      await widget.logout();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeError(e))));
      }
    } finally {
      if (mounted) setState(() => loggingOut = false);
    }
  }

  Widget collectionTile(
    String id,
    String title,
    String subtitle,
    IconData icon,
    double width,
    VoidCallback open,
  ) => SizedBox(
    width: width,
    child: Material(
      color: accentColor(context).withValues(alpha: .055),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('personal-entry-$id'),
        borderRadius: BorderRadius.circular(12),
        onTap: open,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: phoneValue(context, 10, 14),
            vertical: phoneValue(context, 10, 15),
          ),
          child: phoneLayout(context)
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 23, color: accentColor(context)),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 10,
                        color: secondaryColor(context),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Icon(
                      icon,
                      size: phoneValue(context, 21, 24),
                      color: accentColor(context),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              fontSize: 11,
                              color: secondaryColor(context),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    ),
  );

  Widget account() => PageList(
    storageKey: const PageStorageKey('account-page'),
    bottom: browseBottomSpace(context),
    header: const SectionHeading('账户', showPageAction: false),
    children: [
      SettingsGroup(
        children: [
          AccountCard(
            profile: true,
            account: widget.api.session!,
            display: widget.store.accountDisplays.read(widget.api.session!),
            onTap: playing ? null : widget.openAccounts,
          ),
        ],
      ),
      SettingsGroup(
        title: '我的影片',
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, bounds) {
                final columns = phoneLayout(context)
                    ? (MediaQuery.textScalerOf(context).scale(14) <= 18.2
                          ? 3
                          : 2)
                    : bounds.maxWidth >= 580
                    ? 3
                    : 2;
                final width = (bounds.maxWidth - (columns - 1) * 10) / columns;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final list in const [
                      PersonalList.favorites,
                      PersonalList.played,
                      PersonalList.unplayed,
                    ])
                      collectionTile(
                        list.name,
                        list.label,
                        'Emby 同步',
                        switch (list) {
                          PersonalList.favorites => CupertinoIcons.heart,
                          PersonalList.played =>
                            CupertinoIcons.check_mark_circled,
                          PersonalList.unplayed => CupertinoIcons.play_circle,
                          PersonalList.likes => CupertinoIcons.hand_thumbsup,
                          PersonalList.dislikes =>
                            CupertinoIcons.hand_thumbsdown,
                        },
                        width,
                        () => Navigator.push(
                          context,
                          CupertinoPageRoute<void>(
                            builder: (_) => posterActions(
                              PersonalStatusPage(
                                sync: personalSync,
                                list: list,
                                onItem: item,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
      SettingsGroup(
        children: [
          SettingsRow(
            '版本',
            key: const Key('app-version-row'),
            icon: CupertinoIcons.info_circle,
            subtitle: '查看更新说明',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(appVersion, style: TextStyle(fontSize: 14)),
                const SizedBox(width: 8),
                Icon(
                  CupertinoIcons.chevron_forward,
                  size: 15,
                  color: secondaryColor(context),
                ),
              ],
            ),
            onTap: () =>
                showSurface<void>(context, (_) => const ReleaseNotesPage()),
          ),
        ],
      ),
      if (widget.openAccounts != null)
        SettingsGroup(
          footer: '首页、媒体库和设置右上角的头像也可直接切换账号。',
          children: [
            SettingsRow(
              '切换与管理账号',
              key: const Key('manage-accounts-row'),
              icon: CupertinoIcons.person_2,
              subtitle: '切换、添加账号，或设置备注与头像',
              onTap: widget.openAccounts,
            ),
          ],
        ),
      SettingsGroup(
        children: [
          SettingsRow(
            loggingOut ? '正在退出' : '退出当前账号',
            key: const Key('logout-current-account'),
            icon: CupertinoIcons.square_arrow_right,
            destructive: true,
            onTap: loggingOut ? null : confirmLogout,
          ),
        ],
      ),
    ],
  );
}
